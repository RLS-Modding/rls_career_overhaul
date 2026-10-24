local deliveryText = require("overhaul/lib/logistics/resultTranslations")
local _tr = deliveryText.text
local core_locales = {contextTranslate = deliveryText.context}
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/delivery/progress.lua (BeamNG 0.40).
-- Owns delivery progress and drop-off settlement. Reward helpers live in progress/rewards.lua.
-- Read dependency binding, progress tracking, drop-off validation, then settlement phases:
-- summarize rewards, settle escrow, pay, present the result, and complete follow-ups.
-- A refused payment retains the settlement; post-payment failures are isolated by phase.

local recordDelivery = require("overhaul/lib/progression/logbookFeed").register("overhaul.deliveryCompleted", {
  title = "Delivery completed", label = "Logistics", icon = "deliveryTruck"
}, "career/logistics/progress.lua")

local M = {}

local skillLookup = require("overhaul/lib/progression/skillLookup")
local xpConfig = require('overhaul/lib/logistics/xpConfig')
local balance = require('overhaul/lib/logistics/logisticsBalance')

M.dependencies = {"overhaul_shell_stepHandler"}

-- State -------------------------------------------------------------------------------------------
-- Rewards own their pure helpers; delivery services are rebound at career activation.
local rewardServices = require("overhaul/career/logistics/progress/rewards").new({
  xpConfig = xpConfig,
  balance = balance,
})
local dropOffCargoSnapshot
local deliveryServices = {}
local progress = {}

local progressTemplate = {
  deliveryAchievements = {},

  cargoDeliveredByType = {
    parcel = 0,
    vehicle = 0,
    trailer = 0,
    fluid = 0,
    dryBulk = 0,
    cement = 0,
    cash = 0
  }
}

-- Drop-off validation -------------------------------------------------------------------------

local dropOffValidation = {}

-- Where a cargo sat when the drop-off screen opened, so a later move is caught before settling.
function dropOffValidation.capture(cargo)
  local location = cargo.location or {}
  return {cargo = cargo, vehId = location.vehId, containerId = location.containerId,
    slots = cargo.slots, materialType = cargo.materialType, type = cargo.type}
end

local function countCargoIds(allCargo)
  local counts = {}
  for _, cargo in ipairs(allCargo) do
    counts[cargo.id] = (counts[cargo.id] or 0) + 1
  end
  return counts
end

-- An element names one cargo id, or several under `ids`.
local function elementCargoIds(element)
  if type(element.ids) == 'table' and element.ids[1] then return element.ids end
  if element.id then return {element.id} end
  return {}
end

local function allowsRecovery(allowRecoveryCargo, cargo)
  return allowRecoveryCargo and allowRecoveryCargo(cargo)
end

local function changedSinceOpening(expectedCargo, cargo, location)
  return expectedCargo.cargo ~= cargo or expectedCargo.vehId ~= location.vehId
    or expectedCargo.containerId ~= location.containerId or expectedCargo.slots ~= cargo.slots
    or expectedCargo.materialType ~= cargo.materialType or expectedCargo.type ~= cargo.type
end

-- Returns the reason one selected cargo cannot be dropped off here, or nil and the cargo when it can.
local function cargoRefusal(id, getCargoById, accepts, expectedCargoById, allowRecoveryCargo)
  local cargo = getCargoById(id)
  local location = cargo and cargo.location
  if not location then return 'cargo ' .. tostring(id) .. ' has no location' end
  if location.type ~= 'vehicle' and not allowsRecovery(allowRecoveryCargo, cargo) then
    return 'cargo ' .. tostring(id) .. ' is not loaded in a vehicle'
  end
  if cargo.logisticsPending and not allowsRecovery(allowRecoveryCargo, cargo) then
    return 'cargo ' .. tostring(id) .. ' is waiting for vehicle restoration'
  end
  if expectedCargoById then
    local expectedCargo = expectedCargoById[id]
    if not expectedCargo or changedSinceOpening(expectedCargo, cargo, location) then
      return 'cargo changed since opening the drop-off screen'
    end
  end
  if not accepts(cargo) then return 'cargo does not belong at this destination' end
  local data = cargo.data or {}
  local recalculatesRewards = data.materialContractId or data.passiveBusinessSupplyReservationId
    or data.engineShopSupplyReservationId or (cargo.materialType and not cargo.automaticDropOff)
  if not recalculatesRewards and (type(cargo.rewards) ~= 'table' or type(cargo.rewards.money) ~= 'number') then
    return 'cargo reward data is missing'
  end
  return nil, cargo
end

local function amountRefusal(amount, selectedSlots)
  local numeric = tonumber(amount)
  if not numeric or numeric ~= numeric or numeric < 0 or numeric == math.huge or numeric > selectedSlots + 0.0001 then
    return 'requested amount exceeds the selected cargo'
  end
  return nil
end

function dropOffValidation.validate(elements, allCargo, getCargoById, accepts, expectedCargoById, allowRecoveryCargo)
  local cargoCountById, selectedCargoIds = countCargoIds(allCargo), {}
  for _, element in ipairs(elements) do
    local cargoIds = elementCargoIds(element)
    if not cargoIds[1] then return false, 'empty cargo selection' end
    local selectedSlots = 0
    for _, id in ipairs(cargoIds) do
      if cargoCountById[id] ~= 1 or selectedCargoIds[id] then return false, 'missing or duplicate cargo ID ' .. tostring(id) end
      selectedCargoIds[id] = true
      local refusal, cargo = cargoRefusal(id, getCargoById, accepts, expectedCargoById, allowRecoveryCargo)
      if refusal then return false, refusal end
      selectedSlots = selectedSlots + (tonumber(cargo.slots) or 0)
    end
    if element.amount ~= nil then
      local refusal = amountRefusal(element.amount, selectedSlots)
      if refusal then return false, refusal end
    end
  end
  return true
end


-- Binding -----------------------------------------------------------------------------------------
local function bindDeliveryDeps()
  deliveryServices.parcelManager = overhaul_career_logistics_parcelManager
  deliveryServices.cargoScreen = overhaul_career_logistics_cargoScreen
  deliveryServices.general = overhaul_career_logistics_general
  deliveryServices.generator = overhaul_career_logistics_generator
  deliveryServices.progress = overhaul_career_logistics_progress
  deliveryServices.parcelMods = overhaul_career_logistics_parcelMods
  deliveryServices.vehicleOfferManager = overhaul_career_logistics_vehicleOfferManager
  deliveryServices.vehicleTasks = overhaul_career_logistics_vehicleTasks
  deliveryServices.tutorial = overhaul_career_logistics_tutorial
  deliveryServices.tasklist = overhaul_career_logistics_tasklist
  deliveryServices.materialContracts = overhaul_career_logistics_materialContractManager
  deliveryServices.stepHandler = overhaul_shell_stepHandler
  return deliveryServices.generator ~= nil
end

M.onCareerActivated = function()
  bindDeliveryDeps()
end

-- Progress tracking -------------------------------------------------------------------------------
M.setProgress = function(data)
  progress = rewardServices.mergeDefaults(progressTemplate, data or {})
end

M.getProgress = function()
  return progress
end

M.onCargoDelivered = function(cargoItems)
  if overhaul_career_logistics_broker then overhaul_career_logistics_broker.onBrokerCargoDelivered(cargoItems) end
  local ownerOp = overhaul_career_logistics_ownerOpContracts
  if ownerOp and ownerOp.onOwnerOpCargoDelivered then ownerOp.onOwnerOpCargoDelivered(cargoItems) end

  local affectedFacilities = {}

  for _, cargo in ipairs(cargoItems or {}) do
    local cargoType, amount = "parcel", 1
    if cargo.materialType == nil then
      progress.cargoDeliveredByType.parcel = progress.cargoDeliveredByType.parcel + 1
      if deliveryServices.tutorial and deliveryServices.tutorial.onDeliveryCompleted then deliveryServices.tutorial.onDeliveryCompleted("parcel") end
    else
      local material = deliveryServices.generator.getMaterialsTemplatesById(cargo.materialType)
      local slots = tonumber(cargo.slots) or 0
      cargoType, amount = material and material.type, slots
      if material and material.type then
        progress.cargoDeliveredByType[material.type] = (progress.cargoDeliveredByType[material.type] or 0) + slots
      end
      if slots > 0 and deliveryServices.tutorial and deliveryServices.tutorial.onDeliveryCompleted then deliveryServices.tutorial.onDeliveryCompleted("material") end
    end

    local money = cargo.rewards and cargo.rewards.money or 0
    local origFacId = cargo.origin and cargo.origin.facId
    local cargoOrigFacility = origFacId and deliveryServices.generator.getFacilityById(origFacId)
    if cargoOrigFacility and cargoOrigFacility.progress then
      local counts = cargoOrigFacility.progress.deliveredFromHere.countByType
      if cargoType then counts[cargoType] = (counts[cargoType] or 0) + amount end
      cargoOrigFacility.progress.deliveredFromHere.moneySum = cargoOrigFacility.progress.deliveredFromHere.moneySum + money
      affectedFacilities[origFacId] = true
    end

    local destFacId = cargo.location and cargo.location.facId
    local cargoDestFacility = destFacId and deliveryServices.generator.getFacilityById(destFacId)
    if cargoDestFacility and cargoDestFacility.progress then
      local counts = cargoDestFacility.progress.deliveredToHere.countByType
      if cargoType then counts[cargoType] = (counts[cargoType] or 0) + amount end
      cargoDestFacility.progress.deliveredToHere.moneySum = cargoDestFacility.progress.deliveredToHere.moneySum + money
      affectedFacilities[destFacId] = true
    end

    deliveryServices.parcelMods.trackModifierStats(cargo)
  end

  extensions.hook("onOverhaulDeliveryFacilityProgressStatsChanged", affectedFacilities)
end

local function getVehicleOfferDropOffFacId(offer)
  if not offer then return nil end
  if offer.dropOffFacId then return offer.dropOffFacId end
  if offer.destination and offer.destination.facId then return offer.destination.facId end
  local task = offer.task
  if task and task.destination and task.destination.facId then return task.destination.facId end
  if task and task.dropOff and task.dropOff.facId then return task.dropOff.facId end
  return nil
end

M.onVehicleTasksFinished = function(offers)
  if overhaul_career_logistics_broker then overhaul_career_logistics_broker.onBrokerVehicleDelivered(offers) end
  local ownerOp = overhaul_career_logistics_ownerOpContracts
  if ownerOp and ownerOp.onOwnerOpVehicleDelivered then ownerOp.onOwnerOpVehicleDelivered(offers) end
  local affectedFacilities = {}
  for _, o in ipairs(offers or {}) do
    local offer = o.offer
    if not offer or not offer.data or not offer.data.type then goto continue end
    progress.cargoDeliveredByType[offer.data.type] = progress.cargoDeliveredByType[offer.data.type] + 1
    if offer.data.type == "vehicle" and deliveryServices.tutorial and deliveryServices.tutorial.onDeliveryCompleted then deliveryServices.tutorial.onDeliveryCompleted("vehicle") end

    local destFacId = getVehicleOfferDropOffFacId(offer)
    if offer.origin and offer.origin.facId then
      local vehOrigFacility = deliveryServices.generator.getFacilityById(offer.origin.facId)
      if vehOrigFacility and vehOrigFacility.progress then
        vehOrigFacility.progress.deliveredFromHere.countByType[offer.data.type] = vehOrigFacility.progress.deliveredFromHere.countByType[offer.data.type] + 1
        vehOrigFacility.progress.deliveredFromHere.moneySum = vehOrigFacility.progress.deliveredFromHere.moneySum + (offer.rewards.money or 0)
        affectedFacilities[offer.origin.facId] = true
      end
    end

    if destFacId then
      local vehDestFacility = deliveryServices.generator.getFacilityById(destFacId)
      if vehDestFacility and vehDestFacility.progress then
        vehDestFacility.progress.deliveredToHere.countByType[offer.data.type] = vehDestFacility.progress.deliveredToHere.countByType[offer.data.type] + 1
        vehDestFacility.progress.deliveredToHere.moneySum = vehDestFacility.progress.deliveredToHere.moneySum + (offer.rewards.money or 0)
        affectedFacilities[destFacId] = true
      end
    end
    ::continue::
  end
  extensions.hook("onOverhaulDeliveryFacilityProgressStatsChanged", affectedFacilities)
end

-- Skill unlock aggregates -------------------------------------------------------------------------
local unlockStatus = nil
M.aggregateBefore = function()
  unlockStatus = {
    skillLevels = {}
  }
  for skill, _ in pairs(overhaul_career_progression_skills.getBranches()) do
    unlockStatus.skillLevels[skill] = skillLookup.branchLevel(skill)
  end
end

M.aggregateAfter = function()
  -- Skill unlock descriptions are not reported after a delivery yet, so the list is always empty.
  local results = {}
  unlockStatus = nil
  return results
end

-- Drop-off screen ---------------------------------------------------------------------------------
local dropOffDataStatus = nil
local confirmedDropOffData = nil
local dropOffSettlementGeneration = 0
local requestDropOffWeightUpdate
local DROP_OFF_SETTLEMENT_TIMEOUT = 180
local function dropOffSettlementStale()
  return confirmedDropOffData ~= nil and not confirmedDropOffData.payoutComplete
    and confirmedDropOffData.startedAt ~= nil
    and os.clockhp() - (confirmedDropOffData.lastRecoveryAt or confirmedDropOffData.startedAt) > DROP_OFF_SETTLEMENT_TIMEOUT
end

local function retainDropOffSettlement(reason)
  local settling = confirmedDropOffData
  if not settling then return end
  log("E", "delivery", "Drop-off settlement interrupted: " .. tostring(reason))
  settling.settlementError = reason
  if type(settling.onComplete) == "function" then
    local ok, err = pcall(settling.onComplete)
    if not ok then log("E", "delivery", "Drop-off unfreeze failed: " .. tostring(err)) end
  end
  if settling.payoutComplete then
    settling.saveHold.release()
    confirmedDropOffData = nil
    dropOffDataStatus = nil
    dropOffCargoSnapshot = nil
  end
end

local function releaseStaleDropOffSettlement()
  if dropOffSettlementStale() then
    local settling = confirmedDropOffData
    settling.lastRecoveryAt = os.clockhp()
    log("W", "delivery", "Retrying pending drop-off settlement after timeout")
    if settling.payoutStarted or settling.recovering then return end
    settling.recovering = true
    local ok, err = xpcall(function()
      local pendingOfferIds = {}
      for _, offer in ipairs(settling.offers or {}) do
        if not offer.finished and offer.offer then
          pendingOfferIds[#pendingOfferIds + 1] = offer.offer.id
        end
      end
      if #pendingOfferIds > 0 then
        local retriedOffers = deliveryServices.vehicleTasks.finishTasks(pendingOfferIds, settling.missingVehicleDropOff)
        for _, retried in ipairs(retriedOffers or {}) do
          for i, original in ipairs(settling.offers) do
            if original.offer and retried.offer and original.offer.id == retried.offer.id then
              settling.offers[i] = retried
              break
            end
          end
        end
      end
      if not settling.weightUpdateComplete then requestDropOffWeightUpdate(settling) end
    end, debug.traceback)
    settling.recovering = nil
    if not ok then retainDropOffSettlement(err) else M.confirmDropOffCheckComplete() end
  end
end

M.isSettlementPending = function()
  releaseStaleDropOffSettlement()
  return confirmedDropOffData ~= nil and not confirmedDropOffData.payoutComplete
end

local function releaseDropOffHolds()
  require("overhaul/lib/save/store").releaseHolds(M)
end
M.onExtensionUnloaded = releaseDropOffHolds

requestDropOffWeightUpdate = function(settling)
  settling.weightUpdateGeneration = (settling.weightUpdateGeneration or 0) + 1
  local generation = settling.weightUpdateGeneration
  deliveryServices.general.requestUpdateContainerWeights()
  deliveryServices.general.updateContainerWeights(function(data)
    if confirmedDropOffData ~= settling or settling.weightUpdateGeneration ~= generation
        or settling.weightUpdateComplete or settling.payoutComplete then return end
    data = data or {}
    settling.weightUpdateComplete = true
    local maxDelay = 0
    for _, delay in pairs(data) do maxDelay = math.max(delay, maxDelay) end
    settling.maxDelayForWeightUpdate = maxDelay >= 1 and maxDelay or 0
    if maxDelay >= 1 then
      settling.onComplete = function()
        if settling.unfreezeScheduled then return end
        settling.unfreezeScheduled = true
        core_jobsystem.create(function(job)
          job.sleep(maxDelay + 0.5)
          if dropOffSettlementGeneration ~= settling.generation then return end
          for vehId in pairs(data) do
            local veh = scenetree.findObjectById(vehId)
            if veh then core_vehicleBridge.executeAction(veh, 'setFreeze', false) end
          end
        end)
      end
    else
      for vehId in pairs(data) do
        local veh = scenetree.findObjectById(vehId)
        if veh then core_vehicleBridge.executeAction(veh, 'setFreeze', false) end
      end
    end
    M.confirmDropOffCheckComplete()
  end)
end
local pendingEmploymentAfterDropOff = false

local function consumePendingEmploymentAfterDropOff()
  if not pendingEmploymentAfterDropOff then return end
  pendingEmploymentAfterDropOff = false
  local emp = overhaul_career_work_employment
  if emp and emp.afterCompanyDropOff then
    emp.afterCompanyDropOff()
  end
end

local function republishTransferHudAfterDropOffUi()
  local transfer = overhaul_career_logistics_vehicleTransfer
  if transfer and transfer.refreshHudTasklistAfterUi then
    transfer.refreshHudTasklistAfterUi()
  elseif transfer and transfer.isOnShift() then
    transfer.refreshHudTasklist(true)
  end
end

M.requestDropOffData = function(facId, psPath)
  if dropOffDataStatus ~= nil then
    if confirmedDropOffData ~= nil then
      log("W","","Already unloading cargo...")
      return
    end
    log("W","","Clearing stale drop-off data before opening cargo drop-off.")
    dropOffDataStatus = nil
  end
  dropOffDataStatus = {}
  dropOffCargoSnapshot = {}
  dropOffDataStatus.affectedOfferIds = {}
  dropOffDataStatus.parcelData = {}
  dropOffDataStatus.vehicleData = {}
  dropOffDataStatus.trailerData = {}
  dropOffDataStatus.playerVehicleData = {}
  dropOffDataStatus.location = {type="facilityParkingspot", facId=facId, psPath=psPath}
  local rewardKeys = {}
  local playerVehiclesById = {}
  deliveryServices.general.getNearbyVehicleCargoContainers(function(playerCargoContainers)
    local playerDestinationParkingSpots = {}
    local playerVehIds = {}
    for _, con in ipairs(playerCargoContainers) do
      playerVehIds[con.vehId] = true
      for _, cargo in ipairs(con.rawCargo) do
        local validCargo = false
        local contractCargo = cargo.data and cargo.data.materialContractId and cargo.materialType
        if contractCargo and deliveryServices.materialContracts then
          validCargo = deliveryServices.materialContracts.getMaterialDeliveryCapacity(cargo.materialType,
            dropOffDataStatus.location, cargo.data.materialContractId) > 0
        elseif not cargo.destination then
          validCargo = false
        elseif cargo.destination.type == "facilityParkingspot" then
          validCargo = deliveryServices.parcelManager.sameLocation(cargo.destination, dropOffDataStatus.location)
        elseif cargo.destination.type == "multi" then
          for _, dest in ipairs(cargo.destination.destinations) do
            validCargo = validCargo or deliveryServices.parcelManager.sameLocation(dest, dropOffDataStatus.location)
          end
        end

        if validCargo then
          dropOffCargoSnapshot[cargo.id] = dropOffValidation.capture(cargo)
          if not playerVehiclesById[con.vehId] then
            playerVehiclesById[con.vehId] = { containers = {}, niceName = deliveryServices.general.getVehicleName(con.vehId), vehId = con.vehId, containersById = {}}
          end
          if not playerVehiclesById[con.vehId].containersById[con.containerId] then
            playerVehiclesById[con.vehId].containersById[con.containerId] = {
              vehId = con.vehId,
              name = con.name,
              containerId = con.containerId,
              cargo = {},
              totalCargoSlots = con.totalCargoSlots,
              usedCargoSlots = con.usedCargoSlots,
              freeCargoSlots = con.freeCargoSlots,
            }
          end
          local displayCargo = cargo
          if contractCargo and not deliveryServices.parcelManager.sameLocation(cargo.destination, dropOffDataStatus.location) then
            displayCargo = deepcopy(cargo)
            displayCargo.destination = deepcopy(dropOffDataStatus.location)
          end
          table.insert(playerVehiclesById[con.vehId].containersById[con.containerId].cargo, displayCargo)
        end
      end
    end

    dropOffDataStatus.playerVehicleData = {}
    for vehId, vehicleInfo in pairs(playerVehiclesById) do
      for _, id in ipairs(tableKeysSorted(vehicleInfo.containersById)) do
        vehicleInfo.containersById[id].cargo = deliveryServices.parcelManager.addParcelRewardsSummary(deepcopy(vehicleInfo.containersById[id].cargo))
        table.insert(vehicleInfo.containers, vehicleInfo.containersById[id])
      end
      vehicleInfo.containersById = nil
      table.insert(dropOffDataStatus.playerVehicleData, vehicleInfo)
    end
    table.sort(dropOffDataStatus.playerVehicleData, function(a,b) return a.vehId < b.vehId end)
    dropOffDataStatus.rewardKeyIcons = rewardKeys
    dropOffDataStatus.vehicleData = deliveryServices.vehicleTasks.getVehicleDataWithRewardsSummary(psPath)
    local gatherSequence = deliveryServices.vehicleTasks.makeGatherVehicleDataSteps(dropOffDataStatus.vehicleData)
    if #gatherSequence > 0 then
      deliveryServices.stepHandler.startStepSequence(gatherSequence, function()
        M.openDropOffScreenGatheringComplete()
      end)
    else
      M.openDropOffScreenGatheringComplete()
    end
  end)
end

M.unloadMaterialsManualStart = function(cargoId, destination)
  log("W", "logisticsProgress", "No longer used! unloadMaterialsManualStart")
end

local showSystemPopup = {}
M.openDropOffScreenGatheringComplete = function()
  -- patch in xp icons info
  local branchInfo = {}

  -- already calc if we need it
  local confirmedCargoIds = {}
  local confirmedOfferIds = {}

  --sort into automatic and non-automatic
  local automaticDropOffItems = {}
  local manualDropOffItems = {}
  for _, vehicleInfo in pairs(dropOffDataStatus.playerVehicleData or {}) do
    for _, con in pairs(vehicleInfo.containers) do
      for _, cargo in pairs(con.cargo) do
        cargo.vehicleName = vehicleInfo.name
        cargo.containerName = con.name
        if cargo.automaticDropOff then
          table.insert(automaticDropOffItems, cargo)
          for _, id in ipairs(cargo.ids) do
            table.insert(confirmedCargoIds, {id=id})
          end
        else
          table.insert(manualDropOffItems, cargo)
        end
        cargo.adjustedRewards = rewardServices.normalizeRewardTable(cargo.adjustedRewards, cargo.breakdown)
        -- add in rewards keys..?
        for key, amount in pairs(cargo.adjustedRewards) do
          branchInfo[key] = true
        end
      end
    end
  end

  for _, vehData in ipairs(dropOffDataStatus.vehicleData or {}) do
    if vehData.finished then
      table.insert(automaticDropOffItems, vehData)
      table.insert(confirmedOfferIds, vehData.id)
      vehData.adjustedRewards = rewardServices.normalizeRewardTable(vehData.adjustedRewards, vehData.breakdown)
      for key, amount in pairs(vehData.adjustedRewards) do
        branchInfo[key] = true
      end
    end
  end

  -- still waiting for vehicles to be finished, but show UI if there's cargo
  local hasPendingVehicles = false
  for _, data in ipairs(dropOffDataStatus.vehicleData or {}) do
    if not data.finished then
      hasPendingVehicles = true
      break
    end
  end

  -- if we have cargo to show, display UI even if vehicles are still gathering
  local hasCargoToShow = #manualDropOffItems > 0 or #automaticDropOffItems > 0
  if hasPendingVehicles and not hasCargoToShow then
    return
  end

  dropOffDataStatus.automaticDropOffItems = automaticDropOffItems
  dropOffDataStatus.manualDropOffItems = manualDropOffItems

  -- check how much i can unload for each material
  local unloadingMaterialInfoByKey = {}
  local fac = deliveryServices.generator.getFacilityById(dropOffDataStatus.location.facId)
  for _, item in ipairs(manualDropOffItems) do
    local passiveSupplyIds = {}
    local itemIds = type(item.ids) == "table" and item.ids or (item.id and {item.id} or {})
    for _, cargoId in ipairs(itemIds) do
      local rawCargo = deliveryServices.parcelManager.getCargoById(cargoId)
      if rawCargo and rawCargo.data and (rawCargo.data.passiveBusinessSupplyReservationId or rawCargo.data.engineShopSupplyReservationId) then
        table.insert(passiveSupplyIds, cargoId)
      end
    end
    if #passiveSupplyIds > 0 then
      -- Passive-business stock is a whole-pallet parcel, not a material tank.
      -- Send its raw cargo IDs through the normal confirmation pipeline where
      -- deliverSupplyCargo performs the capacity check and credits the store.
      table.insert(confirmedCargoIds, {ids = passiveSupplyIds})
      goto continueManualDropOffItem
    end

    local materialType = item.materialType
    local storage = materialType and fac and fac.materialStorages and fac.materialStorages[materialType]
    if materialType and storage then
      local isContract = item.materialContractId ~= nil or (item.data and item.data.materialContractId ~= nil)
      -- addParcelRewardsSummary clusters cargo before this point and does not
      -- consistently retain the data table. Resolve the original IDs so the
      -- contract/ordinary capacity paths can never be mixed up.
      if not isContract then
        for _, cargoId in ipairs(item.ids or {}) do
          local rawCargo = deliveryServices.parcelManager.getCargoById(cargoId)
          if rawCargo and rawCargo.data and rawCargo.data.materialContractId then
            isContract = true
            break
          end
        end
      end
      local storageKey = string.format("%s|%s", materialType, isContract and "contract" or "storage")
      unloadingMaterialInfoByKey[storageKey] = unloadingMaterialInfoByKey[storageKey] or {
        storage = storage,
        materialType = materialType,
        virtualCapacity = isContract,
        amountToUnload = 0,
        items = {},
      }
      unloadingMaterialInfoByKey[storageKey].amountToUnload = unloadingMaterialInfoByKey[storageKey].amountToUnload + item.slots
      table.insert(unloadingMaterialInfoByKey[storageKey].items, item)
    else
      log("W", "", string.format("Skipping manual drop-off item without receiver storage: %s", item.name or item.id or "unknown cargo"))
    end
    ::continueManualDropOffItem::
  end

  dropOffDataStatus.customAmountPerMaterialType = {}
  for _, storageKey in pairs(tableKeysSorted(unloadingMaterialInfoByKey)) do
    local info = unloadingMaterialInfoByKey[storageKey]
    info.material = deliveryServices.generator.getMaterialsTemplatesById(info.materialType)
    if info.virtualCapacity then
      -- A contract receiver is a project sink, not the facility's normal
      -- inventory tank. Cap the selector at the unfilled amount across every
      -- active contract for this material at this marker.
      local acceptingCapacity = deliveryServices.materialContracts
        and deliveryServices.materialContracts.getMaterialDeliveryCapacity(info.materialType, dropOffDataStatus.location) or 0
      info.storage = {
        capacity = math.min(info.amountToUnload, acceptingCapacity),
        storedVolume = 0,
        target = 0,
        materialType = info.materialType,
      }
    end

    table.insert(dropOffDataStatus.customAmountPerMaterialType, info)
  end

  if next(dropOffDataStatus.customAmountPerMaterialType) then

    for key, _ in pairs(branchInfo) do
      branchInfo[key] = {
        icon = overhaul_career_progression_skills.getBranchIcon(key),
        order = overhaul_career_progression_skills.getOrder(key)
      }
      if key:endswith("Reputation") then
        branchInfo[key].order, branchInfo[key].icon = 7000, "peopleOutline" --overhaul_world_organizations.getOrganizationIdOrderAndIcon()
      end
    end
    --dump(dropOffDataStatus)
    dropOffDataStatus.branchInfo = branchInfo
    guihooks.trigger("SetDeliveryDropOffCargoSelection", dropOffDataStatus)
    overhaul_integration_services_markerInteraction.closeViewDetailPrompt(true)
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Info_Open')
    gameplay_rawPois.clear()
  else
    local confirmedDropOffs = {
      confirmedCargoIds = confirmedCargoIds,
      confirmedOfferIds = confirmedOfferIds,
    }
    M.confirmDropOffData(confirmedDropOffs, dropOffDataStatus.location.facId, dropOffDataStatus.location.psPath)
  end
end

-- Regression entry point for Beam Runner. It exercises the same gathered
-- drop-off pipeline while supplying the normally asynchronous gather result.
M.testOpenDropOffScreenGatheringComplete = function(gatheredStatus)
  if type(gatheredStatus) ~= "table" or type(gatheredStatus.location) ~= "table" then return false end
  dropOffCargoSnapshot = nil
  dropOffDataStatus = gatheredStatus
  M.openDropOffScreenGatheringComplete()
  return true
end

M.confirmDropOffData = function(confirmedDropOffs, facId, psPath, allowRecoveryCargo, missingVehicleDropOff)
  releaseStaleDropOffSettlement()
  -- Callers interpret nil as a successfully started settlement.
  if confirmedDropOffData ~= nil then log("W","","Already dropoffing cargo...") return false end
  local location = {type="facilityParkingspot", facId=facId, psPath=psPath}
  local function accepts(cargo)
    if cargo.data and cargo.data.materialContractId and deliveryServices.materialContracts then
      return deliveryServices.materialContracts.getMaterialDeliveryCapacity(cargo.materialType, location,
        cargo.data.materialContractId) > 0
    end
    local destination = cargo.destination
    if not destination then return false end
    if destination.type == 'multi' then
      for _, dest in ipairs(destination.destinations or {}) do
        if deliveryServices.parcelManager.sameLocation(dest, location) then return true end
      end
      return false
    end
    return deliveryServices.parcelManager.sameLocation(destination, location)
  end
  local valid, reason = dropOffValidation.validate(confirmedDropOffs.confirmedCargoIds or {},
    deliveryServices.parcelManager.getAllCargoCustomFilter(function() return true end), deliveryServices.parcelManager.getCargoById,
    accepts, dropOffDataStatus and dropOffCargoSnapshot or nil, allowRecoveryCargo)
  if not valid then
    log('E', 'delivery', 'Rejected stale or invalid cargo drop-off: ' .. reason)
    dropOffDataStatus, dropOffCargoSnapshot = nil, nil
    ui_message('The cargo selection changed. Reopen the delivery screen and try again.', 8, 'warning')
    return false
  end
  confirmedDropOffData = {saveHold = require("overhaul/lib/save/store").hold(M, "drop-off settlement",
    {recover = releaseStaleDropOffSettlement})}
  dropOffSettlementGeneration = dropOffSettlementGeneration + 1
  confirmedDropOffData.generation = dropOffSettlementGeneration
  confirmedDropOffData.startedAt = os.clockhp()
  confirmedDropOffData.missingVehicleDropOff = missingVehicleDropOff
  confirmedDropOffData.parcelIdElems = confirmedDropOffs.confirmedCargoIds or {}
  confirmedDropOffData.offerIds = confirmedDropOffs.confirmedOfferIds or {}
  confirmedDropOffData.cargo = {}
  confirmedDropOffData.financeVehicleIds = {}
  confirmedDropOffData.financeVehicles = {}
  local financeFacility = deliveryServices.generator.getFacilityById(facId)
  confirmedDropOffData.financeLocation = {locationId = facId, locationName = financeFacility and financeFacility.name}
  --dump(confirmedDropOffs)
  if deliveryServices.general.rememberCurrentCargoWeightVehicles then
    deliveryServices.general.rememberCurrentCargoWeightVehicles()
  end

  local function deliverCargo(cargo, takeAmount)
    local isContractCargo = cargo.data and cargo.data.materialContractId and deliveryServices.materialContracts
    local passiveBusiness = overhaul_career_business_passive
    local isPassiveSupply = cargo.data and cargo.data.passiveBusinessSupplyReservationId and passiveBusiness
    local engineShop = overhaul_career_business_engineShop
    local isEngineSupply = cargo.data and cargo.data.engineShopSupplyReservationId and engineShop
    local supplyModule = isEngineSupply and engineShop or (isPassiveSupply and passiveBusiness or nil)
    if supplyModule and not supplyModule.canDeliverSupplyCargo(cargo, location) then
      ui_message("This Mini Mart cannot accept another supply pallet.", 5, "warning")
      return nil
    end
    if supplyModule then
      if not supplyModule.deliverSupplyCargo(cargo, location) then return nil end
      cargo.rewards = {money = 0}
      cargo.modifiers = {}
    elseif isContractCargo then
      local acceptingCapacity = deliveryServices.materialContracts.getMaterialDeliveryCapacity(cargo.materialType, location,
        cargo.data.materialContractId)
      takeAmount = math.min(tonumber(takeAmount) or cargo.slots, acceptingCapacity)
    end
    if takeAmount then
      takeAmount = tonumber(takeAmount) or 0
      if takeAmount <= 0 then
        return nil
      end
      if takeAmount < cargo.slots then
        local parts = deliveryServices.generator.splitOffPartsFromMaterialCargo(cargo, {takeAmount})
        cargo = parts[2]
      end
    end

    -- Capture the actual carrier before cargo moves or asynchronous settlement starts.
    -- The persisted binding also identifies a known carrier during vehicle restoration.
    local carryingVehicleId = cargo.location and cargo.location.vehId
    local inventoryId = carryingVehicleId and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(carryingVehicleId)
    local boundId = cargo.logisticsBinding and cargo.logisticsBinding.inventoryId
    if not inventoryId and boundId and carryingVehicleId
        and overhaul_career_garage_inventory.getVehicleIdFromInventoryId
        and overhaul_career_garage_inventory.getVehicleIdFromInventoryId(boundId) == carryingVehicleId then
      inventoryId = boundId
    end
    if inventoryId then
      confirmedDropOffData.financeVehicleIds[inventoryId] = true
      confirmedDropOffData.financeVehicles[inventoryId] = require("overhaul/lib/finance/metadata").capture(
        {finance = {vehicleId = inventoryId}}, nil, 0)
    else confirmedDropOffData.financeHasUnknownVehicle = true end
    if cargo._transientMove and deliveryServices.parcelManager.clearTransientMoveForCargo then
      deliveryServices.parcelManager.clearTransientMoveForCargo(cargo.id)
    end
    deliveryServices.parcelManager.changeCargoLocation(cargo.id, location)

    if isContractCargo then
      local credited
      local allocations
      cargo.rewards, credited, allocations = deliveryServices.materialContracts.creditMaterialDelivery(cargo.materialType,
        location, cargo.slots, cargo.data.materialContractId)
      cargo.rewards = cargo.rewards or {money = 0}
      cargo.data.fulfilledMaterialContracts = allocations
      if credited < cargo.slots - 0.0001 then
        log("W", "", string.format("Only credited %0.1fL of %0.1fL %s contract cargo", credited, cargo.slots, tostring(cargo.materialType)))
      end
    elseif cargo.materialType and not cargo.automaticDropOff then
      deliveryServices.generator.finalizeMaterialDistanceRewards(cargo, location)
    end

    cargo.originalRewards, cargo.breakdown, cargo.adjustedRewards = deliveryServices.parcelManager.getRewardsWithBreakdown(cargo)
    cargo.adjustedRewards = rewardServices.normalizeRewardTable(cargo.adjustedRewards, cargo.breakdown)
    local empPay = overhaul_career_work_employment
    if empPay and empPay.applyEmploymentPayToBreakdown then
      cargo.originalRewards, cargo.breakdown, cargo.adjustedRewards =
        empPay.applyEmploymentPayToBreakdown(cargo.originalRewards, cargo.breakdown, cargo.adjustedRewards)
      cargo.adjustedRewards = rewardServices.normalizeRewardTable(cargo.adjustedRewards, cargo.breakdown)
    end
    table.insert(confirmedDropOffData.cargo, cargo)
    return cargo
  end

  for _, elem in ipairs(confirmedDropOffData.parcelIdElems) do
    local ids = type(elem.ids) == "table" and elem.ids or nil
    if not ids or not ids[1] then
      ids = elem.id and {elem.id} or {}
    end
    local remaining = tonumber(elem.amount)
    for _, cargoId in ipairs(ids) do
      local cargo = deliveryServices.parcelManager.getCargoById(cargoId)
      if not cargo then
        log("W", "", string.format("Skipping missing cargo during drop-off confirmation: %s", tostring(cargoId)))
      elseif remaining ~= nil and remaining <= 0 then
        break
      else
        local takeAmount = remaining
        if remaining ~= nil then
          takeAmount = math.min(remaining, cargo.slots)
          remaining = remaining - takeAmount
        end
        deliverCargo(cargo, takeAmount)
      end
    end
    if remaining and remaining > 0.0001 then
      log("W", "", string.format("Drop-off amount %s could not be fully consumed from cargo ids %s", tostring(elem.amount), dumps(ids)))
    end
  end

  confirmedDropOffData.weightUpdateComplete = false
  confirmedDropOffData.onComplete = nop
  confirmedDropOffData.offers = deliveryServices.vehicleTasks.finishTasks(confirmedDropOffData.offerIds, missingVehicleDropOff)
  -- Task cleanup restores reusable offer markers while weight updates can still
  -- be outstanding. Retain the dispatch identity in this settlement's lifetime.
  confirmedDropOffData.dismissImmediately = #(confirmedDropOffData.offers or {}) > 0 and #confirmedDropOffData.cargo == 0
  confirmedDropOffData.sourceAppIds = {}
  for _, entry in ipairs(confirmedDropOffData.offers or {}) do
    if not (entry.offer and entry.offer.carGoTransfer) then confirmedDropOffData.dismissImmediately = false end
    confirmedDropOffData.sourceAppIds[(entry.offer and entry.offer.sourceAppId) or "logistics"] = true
  end
  for _, cargo in ipairs(confirmedDropOffData.cargo) do
    confirmedDropOffData.sourceAppIds[cargo.sourceAppId or "logistics"] = true
  end
  requestDropOffWeightUpdate(confirmedDropOffData)
end

-- Drop-off settlement -----------------------------------------------------------------------------
local function refreshBusinessSupplyRoute(deliveredCargo)
  for _, cargo in ipairs(deliveredCargo or {}) do
    if cargo.data and cargo.data.passiveBusinessSupplyReservationId then
      local screen = overhaul_career_logistics_cargoScreen
      if screen and screen.setBestRoute then screen.setBestRoute(true) end
      return
    end
  end
end

-- Keep each post-payment follow-up independent: a UI failure must not skip job completion.
local function settleStep(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then log("E", "delivery", "Drop-off " .. name .. " failed: " .. tostring(err)) end
  return ok
end

local function summarizeDropOffRewards()
  local rewards = {}
  local itemNames = {}
  local rewardParcels = {}
  local levelMoneyBonusMultiplier = rewardServices.getLogisticsMoneyBonusState()

  -- The caller guarantees a common destination for the grouped cargo.
  local cargoBySummaryId = {}
  for _, cargo in ipairs(confirmedDropOffData.cargo) do
    local summaryId = string.format("%s-%s", tostring(cargo.groupId or cargo.id or 0), tostring(cargo.loadedAtTimeStamp or -1))
    cargoBySummaryId[summaryId] = cargoBySummaryId[summaryId] or {}
    -- finalize the fields that require "costly" computation at this point
    table.insert(cargoBySummaryId[summaryId], cargo)
    cargo.adjustedRewards = rewardServices.normalizeRewardTable(cargo.adjustedRewards, cargo.breakdown)
    if not (cargo.data and (cargo.data.materialContractId or cargo.data.passiveBusinessSupplyReservationId or cargo.data.engineShopSupplyReservationId)) then
      rewardServices.applyLogisticsMoneyBonusToEntry(cargo, levelMoneyBonusMultiplier)
    end
    table.insert(rewards, cargo.adjustedRewards)
    cargo.summaryId = summaryId
    table.insert(rewardParcels, cargo)
  end
  for summaryId, group in pairs(cargoBySummaryId) do
    table.insert(itemNames, string.format("%dx %s", #group, _tr(group[1].name)))
  end

  for _, formattedOffer in ipairs(confirmedDropOffData.offers) do
    table.insert(itemNames, string.format("%s %s",formattedOffer.offer.name, formattedOffer.offer.vehicle.name))
    formattedOffer.adjustedRewards = rewardServices.normalizeRewardTable(formattedOffer.adjustedRewards, formattedOffer.breakdown)
    if not (formattedOffer.offer and formattedOffer.offer.data
        and formattedOffer.offer.data.logisticsBonusIncluded) then
      rewardServices.applyLogisticsMoneyBonusToEntry(formattedOffer, levelMoneyBonusMultiplier)
    end
    table.insert(rewards, formattedOffer.adjustedRewards)
  end

  local rewardSum = {}
  for _, reward in ipairs(rewards) do
    for key, amount in pairs(rewardServices.normalizeRewardTable(reward)) do
      rewardSum[key] = (rewardSum[key] or 0) + amount
    end
  end
  rewardSum = rewardServices.normalizeRewardTable(rewardSum)

  return {
    itemNames = itemNames,
    rewardParcels = rewardParcels,
    rewardSum = rewardSum,
  }
end

local function settleDropOffEscrow(rewardSum)
  local payoutSum = deepcopy(rewardSum)
  local branchInfo = {}
  local contractProgressList = {}
  local contractRewardsHeld = false
  local contractJustCompleted = false
  local materialContractIdList = {}
  local materialContractIdSeen = {}

  for _, cargo in ipairs(confirmedDropOffData.cargo or {}) do
    local contractId = cargo.data and cargo.data.materialContractId
    if contractId then
      local idKey = tostring(contractId)
      if not materialContractIdSeen[idKey] then
        materialContractIdSeen[idKey] = true
        materialContractIdList[#materialContractIdList + 1] = contractId
      end
      if deliveryServices.materialContracts and deliveryServices.materialContracts.accrueEscrowRewards then
        deliveryServices.materialContracts.accrueEscrowRewards(contractId, cargo.adjustedRewards)
      end
      for key, amount in pairs(cargo.adjustedRewards or {}) do
        local value = tonumber(amount) or 0
        if value ~= 0 then
          payoutSum[key] = (tonumber(payoutSum[key]) or 0) - value
          if math.abs(payoutSum[key] or 0) < 0.0001 then payoutSum[key] = nil end
        end
      end
    end
  end

  if #materialContractIdList > 0 and deliveryServices.materialContracts then
    if deliveryServices.materialContracts.claimCompletedContractPayouts then
      for _, payout in ipairs(deliveryServices.materialContracts.claimCompletedContractPayouts() or {}) do
        contractJustCompleted = true
        for key, amount in pairs(payout.rewards or {}) do
          local value = tonumber(amount) or 0
          if value ~= 0 then
            payoutSum[key] = (tonumber(payoutSum[key]) or 0) + value
          end
        end
        contractProgressList[#contractProgressList + 1] = {
          kind = "material",
          id = payout.id,
          name = payout.name,
          units = payout.units,
          deliveredAmount = payout.deliveredAmount,
          totalAmount = payout.totalAmount,
          escrowedMoney = math.floor(tonumber(payout.rewards and payout.rewards.money) or 0),
          escrowedRewards = deepcopy(payout.rewards or {}),
          complete = true,
        }
      end
    end
    if deliveryServices.materialContracts.getActiveContractProgressSnapshots then
      for _, snap in ipairs(deliveryServices.materialContracts.getActiveContractProgressSnapshots(materialContractIdList) or {}) do
        if not snap.complete then
          contractRewardsHeld = true
          contractProgressList[#contractProgressList + 1] = {
            kind = "material",
            id = snap.id,
            name = snap.name,
            units = snap.units,
            deliveredAmount = snap.deliveredAmount,
            totalAmount = snap.totalAmount,
            remainingAmount = snap.remainingAmount,
            escrowedMoney = math.floor(tonumber(snap.escrowedMoney) or 0),
            complete = false,
          }
        end
      end
    end
  end

  local ownerOp = overhaul_career_logistics_ownerOpContracts
  if ownerOp and ownerOp.consumeVehicleDropOffForContractEscrow then
    local finkProgress
    payoutSum, finkProgress = ownerOp.consumeVehicleDropOffForContractEscrow(payoutSum, confirmedDropOffData)
    if finkProgress then
      if finkProgress.complete then
        contractJustCompleted = true
      else
        contractRewardsHeld = true
      end
      contractProgressList[#contractProgressList + 1] = finkProgress
    end
  end

  local employment = overhaul_career_work_employment
  if employment and employment.consumeDropOffMoneyForEscrow then
    payoutSum = employment.consumeDropOffMoneyForEscrow(payoutSum, confirmedDropOffData) or payoutSum
  end
  -- Escrow providers add independent sources, so alias amounts must remain additive.
  payoutSum = rewardServices.normalizeRewardTable(payoutSum, nil, true)
  for key, _ in pairs(payoutSum) do
    branchInfo[key] = true
  end
  return {
    payoutSum = payoutSum,
    branchInfo = branchInfo,
    contractProgressList = contractProgressList,
    contractRewardsHeld = contractRewardsHeld,
    contractJustCompleted = contractJustCompleted,
    employment = employment,
  }
end

local function describeDropOffPayment()
  local rewardTags = {"gameplay", "deliveryReward"}
  local typeSeen = {}
  for _, cargo in ipairs(confirmedDropOffData.cargo or {}) do
    local ecoKey
    if cargo.materialType then
      local mat = deliveryServices.generator.getMaterialsTemplatesById and deliveryServices.generator.getMaterialsTemplatesById(cargo.materialType)
      local matType = mat and mat.type
      ecoKey = require('overhaul/lib/logistics/cargoSemantics').material(matType).economyKey
    else
      ecoKey = "delivery_parcel"
    end
    if ecoKey and not typeSeen[ecoKey] then
      typeSeen[ecoKey] = true
      table.insert(rewardTags, ecoKey)
    end
  end
  if confirmedDropOffData.offers and #confirmedDropOffData.offers > 0 then
    if not typeSeen["delivery_vehicle"] then
      table.insert(rewardTags, "delivery_vehicle")
      typeSeen["delivery_vehicle"] = true
    end
  end

  -- Best stamped demand multiplier from this drop-off (baked at offer generation).
  local stampedDemandFactor, stampedDemandBonus = 1, 0
  local function considerStampedDemand(rewardTable)
    if type(rewardTable) ~= "table" then return end
    local m = tonumber(rewardTable.economyMultiplier) or 1
    local money = tonumber(rewardTable.money) or 0
    if m > stampedDemandFactor then stampedDemandFactor = m end
    if money > 0 and m > 1.001 then
      stampedDemandBonus = stampedDemandBonus + money * (m - 1) / m
    end
  end
  local function firstStampedReward(...)
    for i = 1, select("#", ...) do
      local rewardTable = select(i, ...)
      if type(rewardTable) == "table" and rewardTable.economyMultiplier ~= nil then
        return rewardTable
      end
    end
  end
  for _, cargo in ipairs(confirmedDropOffData.cargo or {}) do
    considerStampedDemand(firstStampedReward(cargo.rewards, cargo.originalRewards, cargo.adjustedRewards))
  end
  for _, offerData in ipairs(confirmedDropOffData.offers or {}) do
    local offer = offerData.offer or offerData
    considerStampedDemand(firstStampedReward(
      offer and offer.rewards,
      offerData.originalRewards,
      offerData.adjustedRewards,
      offerData.formatted and offerData.formatted.rewards
    ))
  end

  return {
    rewardTags = rewardTags,
    stampedDemandFactor = stampedDemandFactor,
    stampedDemandBonus = stampedDemandBonus,
  }
end

local function payDropOffRewards(payoutSum, itemNames, paymentDetails)
  local rewardTags = paymentDetails.rewardTags
  local stampedDemandFactor = paymentDetails.stampedDemandFactor
  local finance = {source = "delivery", sourceName = "Delivery"}
  for key, value in pairs(confirmedDropOffData.financeLocation or {}) do finance[key] = value end
  -- A combined settlement must not assign several vehicles' earnings to just one car.
  local carrier = require("overhaul/lib/finance/vehicleContext").single(confirmedDropOffData.financeVehicleIds,
    confirmedDropOffData.financeVehicles, confirmedDropOffData.financeHasUnknownVehicle, #(confirmedDropOffData.offers or {}))
  for key, value in pairs(carrier) do finance[key] = value end
  local paidRewards = deepcopy(payoutSum)
  local valuesBefore = {}
  for key in pairs(payoutSum) do
    if key ~= "money" then
      valuesBefore[key] = overhaul_career_economy_playerAttributes.getAttributeValue(key)
    end
  end
  if next(payoutSum) then
    -- Penalties and the loaner cut can outweigh the pay; the settlement still completes with a net debit.
    local xp = {}
    for key, amount in pairs(payoutSum) do
      if key ~= "money" then xp[key] = amount end
    end
    local accepted, problem = overhaul_career_economy_payment.payout({
      amount = payoutSum.money,
      xp = xp,
      label = {
        txt = "ui.career.attributeLog.deliveryRewardsFor",
        context = { items = table.concat(itemNames, ", ") },
      },
      tags = rewardTags,
      category = "activity:delivery",
      reason = {finance = finance, demandFactor = (stampedDemandFactor > 1.001) and stampedDemandFactor or nil},
      fullReward = true,
      allowNetDebit = true,
    })
    -- Raising keeps the settlement retained and unreplayed, like any other failed payment here.
    if accepted ~= true then error("drop-off payout refused: " .. tostring(problem)) end
  end
  -- Reputation can clamp at its bounds; show the observed gain, not the requested gain.
  for key, before in pairs(valuesBefore) do
    paidRewards[key] = overhaul_career_economy_playerAttributes.getAttributeValue(key) - before
  end
  confirmedDropOffData.payoutComplete = true
  confirmedDropOffData.saveHold.release()
  return paidRewards
end

local function buildDropOffPopupBranchInfo(branchInfo)
  for key, _ in pairs(branchInfo) do

    if key:endswith("Reputation") then
      local orgId = key:sub(1, -11)
      local organization = overhaul_world_organizations.getOrganization(orgId)
      branchInfo[key] = {
        icon = "peopleOutline",
        order = 7000,
        animationData = {
          name = core_locales.contextTranslate("ui.career.organizations.reputationAnimationName", {organizationName = _tr(organization.name)}),
          max = organization.reputation.nextThreshold,
          min = organization.reputation.prevThreshold,
          value = organization.reputation.value
        },
        type = "reputation",
        branchLevels = organization.reputationLevels
      }
    else
      local branch = rewardServices.getBranchForAttributeKey(key)
      if branch and not branch.missing then
        local branchLevels = rewardServices.sanitizeBranchLevels(branch.levels)
        local animationData = rewardServices.getAnimationDataForBranch(key, branch, branchLevels)
        local hasValidLevels = #branchLevels > 0 and type(branchLevels[1].requiredValue) == "number"
        branchInfo[key] = {
          type = "xp",
          -- the branch that owns the key decides the icon (getBranchIcon looks up by branch id, see playerAttributes)
          icon = branch.icon or overhaul_career_progression_skills.getBranchIcon(key),
          order = overhaul_career_progression_skills.getOrder(key) or branch.order or 9999,
          animationData = animationData,
          branchLevels = branchLevels,
          showLevelUpPopup = hasValidLevels and not rewardServices.suppressedDeliveryLevelPopupAttributes[key],
          unlockPopupHeader = core_locales.contextTranslate("ui.career.delivery.progress.unlockPopupHeader", {
            branchName = translateLanguage(branch.name, branch.name),
            branchType = _tr(branch.isSkill and "ui.career.delivery.progress.skill" or "ui.career.delivery.progress.branch"),
            level = animationData.level or 0
          })
        }
        if type(branchInfo[key].animationData.levelLabel) == "table" then
          branchInfo[key].animationData.levelLabel = core_locales.contextTranslate("ui.career.delivery.progress.level", {level = branchInfo[key].animationData.level or 0})
        end

        if branch.isBranch then branchInfo[key].animationData.name = core_locales.contextTranslate("ui.career.delivery.progress.branchName", {name = translateLanguage(branchInfo[key].animationData.name, branchInfo[key].animationData.name)}) end
        if branch.isSkill then branchInfo[key].animationData.name = core_locales.contextTranslate("ui.career.delivery.progress.skillName", {name = translateLanguage(branchInfo[key].animationData.name, branchInfo[key].animationData.name)}) end
      else
        branchInfo[key] = {
          icon = overhaul_career_progression_skills.getBranchIcon(key) or "beamXPLo",
          order = overhaul_career_progression_skills.getOrder(key) or 9999,
          animationData = {
            type = "number",
            name = key,
            value = overhaul_career_economy_playerAttributes.getAttributeValue(key)
          },
          branchLevels = {},
          showLevelUpPopup = false,
        }
      end
    end

    if key == "money" then
      branchInfo[key].icon = "beamCurrency"
      branchInfo[key].animationData = {
        type = "number",
        name = _tr("ui.career.delivery.progress.money"),
        value = overhaul_career_economy_playerAttributes.getAttribute("money").value
      }
    end

    if key == "beamXP" then
      branchInfo[key].type = "xp"
      branchInfo[key].icon = "beamXPLo"
      branchInfo[key].animationData = {
        type = "number",
        name = _tr("ui.career.delivery.progress.beamXP"),
        value = overhaul_career_economy_playerAttributes.getAttribute("beamXP").value
      }
    end
  end
  local popupBranchInfo = deepcopy(branchInfo)
  for key, _ in pairs(rewardServices.hiddenDeliveryPopupAttributes) do
    popupBranchInfo[key] = nil
  end

  return popupBranchInfo
end

local function presentDropOffRewards(rewardParcels, settlement, paymentDetails, onCompanyShift)
  local payoutSum = settlement.payoutSum
  local employment = settlement.employment
  local popupBranchInfo, rewardResult
  local skipRewardPopup = false
  local popupOk = settleStep("reward popup", function()
    popupBranchInfo = buildDropOffPopupBranchInfo(settlement.branchInfo)

    local popupRewardParcels = deepcopy(rewardParcels)
    for _, parcel in ipairs(popupRewardParcels) do
      rewardServices.sanitizePopupRewardContainer(parcel)
    end

    local popupRewardOffers = deepcopy(confirmedDropOffData.offers or {})
    for _, offerData in ipairs(popupRewardOffers) do
      rewardServices.sanitizePopupRewardContainer(offerData)
      local offer = offerData.offer
      if offer then
        local pickupId = offer.origin and offer.origin.facId
        local dropOffId = getVehicleOfferDropOffFacId(offer)
        local pickup = pickupId and deliveryServices.generator.getFacilityById(pickupId)
        local dropOff = dropOffId and deliveryServices.generator.getFacilityById(dropOffId)
        offer.resultRoute = {pickupName = pickup and pickup.name, dropOffName = dropOff and dropOff.name}
      end
    end

    rewardResult = {
      payoutRewards = deepcopy(settlement.paidRewards),
      rewardParcels = popupRewardParcels,
      rewardOffers = popupRewardOffers,
      branchInfo = popupBranchInfo,
      unloadingDelay = confirmedDropOffData.maxDelayForWeightUpdate,
      demandInfo = nil,
      contractProgress = (#settlement.contractProgressList > 0) and settlement.contractProgressList or nil,
      contractRewardsHeld = false,
      contractJustCompleted = settlement.contractJustCompleted or false,
    }
    local hasImmediatePayout = false
    for _, amount in pairs(payoutSum or {}) do
      if math.abs(tonumber(amount) or 0) > 0.0001 then
        hasImmediatePayout = true
        break
      end
    end
    rewardResult.contractRewardsHeld = settlement.contractRewardsHeld and not settlement.contractJustCompleted and not hasImmediatePayout

    local hotThreshold = overhaul_career_economy_activityHeat.HOT_THRESHOLD or 1.10
    if paymentDetails.stampedDemandFactor >= hotThreshold and paymentDetails.stampedDemandBonus >= 1 then
      rewardResult.demandInfo = {
        factor = paymentDetails.stampedDemandFactor,
        pct = math.floor((paymentDetails.stampedDemandFactor - 1) * 100 + 0.5),
        bonusMoney = math.floor(paymentDetails.stampedDemandBonus + 0.5),
        label = "High demand",
      }
    end

    local function cargoIsBusinessSupply(cargo)
      return cargo and cargo.data and (cargo.data.passiveBusinessSupplyReservationId or cargo.data.engineShopSupplyReservationId) and true or false
    end
    local supplyOnlyDropOff = #(confirmedDropOffData.offers or {}) == 0
      and #(confirmedDropOffData.cargo or {}) > 0
    if supplyOnlyDropOff then
      for _, cargo in ipairs(confirmedDropOffData.cargo) do
        if not cargoIsBusinessSupply(cargo) then
          supplyOnlyDropOff = false
          break
        end
      end
    end

    -- A completed drive-off is already paid; its result must never gate the next assignment.
    rewardResult.dismissImmediately = confirmedDropOffData.dismissImmediately
    -- Carry the dispatching app identity to the shared results view. Unstamped
    -- freelance work belongs to this logistics app; mixed sources stay generic.
    local sourceAppIds = confirmedDropOffData.sourceAppIds or {}
    local sourceAppId
    for appId in pairs(sourceAppIds) do
      if sourceAppId then sourceAppId = nil; break end
      sourceAppId = appId
    end
    rewardResult.sourceAppId = sourceAppId
    skipRewardPopup = supplyOnlyDropOff or onCompanyShift
    pendingEmploymentAfterDropOff = false
    if skipRewardPopup then
      if onCompanyShift and employment and employment.isEmployeeDropOffOpen()
          and employment.recordDropOffRewardProgress then
        employment.recordDropOffRewardProgress(rewardServices.buildEmployeeRepDelta(payoutSum, popupBranchInfo))
      end
      if not (employment and employment.isEmployeeDropOffOpen()) then
        guihooks.trigger("ChangeState", { state = "play" })
        if deliveryServices.general.setDeliveryTimePaused then
          deliveryServices.general.setDeliveryTimePaused(false)
        end
        if simTimeAuthority and simTimeAuthority.pause then
          simTimeAuthority.pause(false)
        end
      end
      if supplyOnlyDropOff then
        local n = #confirmedDropOffData.cargo
        ui_message(string.format("Delivered %d supply pallet%s. No delivery pay — the business earns the margin.", n, n == 1 and "" or "s"), 6, "info")
      end
    else
      guihooks.trigger("SetDeliveryDropOffRewardResult", rewardResult)
      Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_02')
      if onCompanyShift then
        pendingEmploymentAfterDropOff = true
      end
    end

    overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt(true)
    gameplay_rawPois.clear()
  end)
  if not popupOk then
    skipRewardPopup = true
    pendingEmploymentAfterDropOff = false
    if not (employment and employment.isEmployeeDropOffOpen()) then
      guihooks.trigger("ChangeState", { state = "play" })
      if deliveryServices.general.setDeliveryTimePaused then
        deliveryServices.general.setDeliveryTimePaused(false)
      end
      if simTimeAuthority and simTimeAuthority.pause then
        simTimeAuthority.pause(false)
      end
    end
  end

  return skipRewardPopup
end

local function completeDropOffSettlement(settling, employment, onCompanyShift, skipRewardPopup)
  settleStep("vehicle task completion", function() M.onVehicleTasksFinished(settling.offers) end)
  settleStep("cargo completion", function() M.onCargoDelivered(settling.cargo) end)
  settleStep("material contract completion", function()
    if deliveryServices.materialContracts then deliveryServices.materialContracts.finalizeCompletedContracts() end
  end)
  settleStep("tasklist update", function()
    for _, offer in ipairs(settling.offers or {}) do
      if offer.offer and offer.offer.id then
        deliveryServices.tasklist.clearTasklistForOfferId(offer.offer.id)
      end
    end
    deliveryServices.tasklist.sendCargoToTasklist()
  end)
  settleStep("unfreeze", function() settling.onComplete() end)
  settleStep("delivery mode exit", function() deliveryServices.general.checkExitDeliveryMode() end)
  settleStep("supply route refresh", function() refreshBusinessSupplyRoute(settling.cargo) end)
  settling.saveHold.release()
  confirmedDropOffData = nil
  dropOffDataStatus = nil
  dropOffCargoSnapshot = nil

  if skipRewardPopup then
    if onCompanyShift and employment and employment.afterCompanyDropOff then
      employment.afterCompanyDropOff()
    end
    republishTransferHudAfterDropOffUi()
  end

  if overhaul_career_career.isAutosaveEnabled() then
    require("overhaul/lib/save/store").request("logisticsProgress:dropOffComplete")
  end
end

local function confirmDropOffCheckCompleteUnsafe()
  if not confirmedDropOffData or confirmedDropOffData.recovering then return end
  -- Both task completion and the weight callback must arrive before settlement.
  for _, data in ipairs(confirmedDropOffData.offers or {}) do
    if not data.finished then return end
  end
  if not confirmedDropOffData.weightUpdateComplete then
    return
  end
  if confirmedDropOffData.payoutComplete or confirmedDropOffData.payoutStarted then
    return
  end
  confirmedDropOffData.payoutStarted = true

  local summary = summarizeDropOffRewards()
  local settlement = settleDropOffEscrow(summary.rewardSum)
  local paymentDetails = describeDropOffPayment()
  settlement.paidRewards = payDropOffRewards(settlement.payoutSum, summary.itemNames, paymentDetails)

  local employment = settlement.employment
  local settling = confirmedDropOffData
  local onCompanyShift = employment and (
    (employment.isOnShift())
    or (employment.isAssignmentPaused())
  ) or false
  if not onCompanyShift and not settlement.contractRewardsHeld then
    recordDelivery({title = settlement.contractJustCompleted and "Broker load completed" or nil,
      detail = table.concat(summary.itemNames, ", "), money = settlement.paidRewards.money})
  end
  local skipRewardPopup = presentDropOffRewards(summary.rewardParcels, settlement, paymentDetails, onCompanyShift)
  completeDropOffSettlement(settling, employment, onCompanyShift, skipRewardPopup)
end

M.confirmDropOffCheckComplete = function()
  local settling = confirmedDropOffData
  local ok, err = xpcall(confirmDropOffCheckCompleteUnsafe, debug.traceback)
  if ok then return end
  if settling and confirmedDropOffData == settling then
    retainDropOffSettlement(err)
  else
    log("E", "delivery", "Drop-off settlement follow-up failed: " .. tostring(err))
  end
end

M.unloadCargoPopupClosed = function()
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_02')
  overhaul_career_guide_tutorialPopups.introPopup("cargoDelivered")
  if next(showSystemPopup) then
    for _, key in ipairs(showSystemPopup) do
      overhaul_career_guide_tutorialPopups.introPopup(key.."Unlocked")
    end
  end
  overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt()
  consumePendingEmploymentAfterDropOff()
  republishTransferHudAfterDropOffUi()
end

M.dropOffPopupClosed = function(mode)
  if mode == "cargoSelection" and confirmedDropOffData == nil then
    dropOffDataStatus = nil
    dropOffCargoSnapshot = nil
  end
  if mode == "results" then
    consumePendingEmploymentAfterDropOff()
    republishTransferHudAfterDropOffUi()
  end
end

-- Facility unlocks --------------------------------------------------------------------------------
M.isFacilityUnlocked = function(facId)
  if not bindDeliveryDeps() then return false end
  local fac = deliveryServices.generator.getFacilityById(facId)
  if not fac then
    return false
  end
  if not fac.unlockCondition then
    return true
  end
  if fac.unlockCondition.type == "minItemCount" then
    local val = fac.progress.itemsDeliveredToHere.count
    local tgt = fac.unlockCondition.target
    if val >= tgt then
      return true
    else
      return false, {
        disabledReasonHeader = "Facility not yet unlocked!",
        disabledReasonContent = string.format("Deliver %d Items here to be able to deliver from here.",tgt),
        progress = {
          {type="progressBar",minValue=0,maxValue=tgt,currValue=val, label=string.format("%d / %d Items delivered.", val, tgt)}
        }
      }
    end
  elseif fac.unlockCondition.type == "branchLevel" then
  end
  return true
end

M.isFacilityVisible = function(facId)
  if not bindDeliveryDeps() then return false end

  local fac = deliveryServices.generator.getFacilityById(facId)
  if not fac then
    return false
  end
  if not fac.visibleCondition then
    return true
  end
  if fac.visibleCondition.type == "minItemCount" then
    local val = fac.progress.itemsDeliveredToHere.count
    local tgt = fac.unlockCondition.target
    if val >= tgt then
      return true
    else
      return false
    end
  end
  return true
end

M.getFacilityCountForCargoCount = function(direction)
  local count = 0
  for _, facility in ipairs(deliveryServices.generator.getFacilities()) do
    local c = 0
    for key, v in pairs(facility.progress[direction].countByType) do
      c = c + v
    end
    if c > 0 then count = count + 1 end
  end
  return count
end

M.getMoneyMultiplerForSkill = function(skill, tier)
  return overhaul_career_progression_skills.getLevelRewardMultiplier("logistics")
end

-- Sounds and hooks --------------------------------------------------------------------------------
local function onOverhaulBranchTierReached(skill, tier)
  if skill == "logistics-delivery" then return end
end

local soundObjectIds = {}
local soundNames = {
  money = 'event:>UI>Career>Progress_Money',
  progressBar = 'event:>UI>Career>Progress_XP'
}

local function activateSound(soundLabel, active)
  soundObjectIds["money"] = soundObjectIds["money"] or Engine.Audio.createSource('AudioGui', soundNames["money"])
  soundObjectIds["progressBar"] = soundObjectIds["progressBar"] or Engine.Audio.createSource('AudioGui', soundNames["progressBar"])
  if active then
    local sound = scenetree.findObjectById(soundObjectIds[soundLabel])
    if sound then
      sound:play(-1)
    end
  else
    for label, _ in pairs(soundNames) do
      local sound = scenetree.findObjectById(soundObjectIds[label])
      if sound then
        sound:stop(-1)
      end
    end
  end
end
M.activateSound = activateSound
-- Share of base pay added at drop-off for the player's Logistics level (0..2); the Job Broker lists pay with it.
M.getLogisticsMoneyBonus = function() return rewardServices.getLogisticsMoneyBonusState() end

M.onOverhaulBranchTierReached = onOverhaulBranchTierReached

return M
