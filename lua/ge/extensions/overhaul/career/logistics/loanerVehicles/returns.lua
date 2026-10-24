-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Loaner returns, fines and employment notices; the update bills rentals and watches walk-away timers.
-- Read damageFineApplies, chargeDamagedReturn, returnVehicleActual, returnVehicle, returnVehicles in order.

local issued = require('overhaul/lib/vehicles/issued')

local returns = {}

-- The walk-away watch runs on this real-time cadence; dtSim is banked across skipped frames.
local UPDATE_INTERVAL_SECONDS = 0.25
-- A rental that comes back damaged pays half of what a work loan would cost.
local RENTAL_DAMAGE_REPUTATION_SHARE = 0.5
local DEFAULT_DAMAGE_REPUTATION_EVENT = -20

function returns.new(inputs)
  local loanerState = inputs.state
  local walkAway, offers, billing = inputs.walkAway, inputs.offers, inputs.billing

  local walkAwayRadiusSquared = walkAway.radiusMeters * walkAway.radiusMeters
  local comeBackRadiusSquared = walkAway.comeBackRadiusMeters * walkAway.comeBackRadiusMeters
  local vehiclePosition = vec3()
  local playerPosition = vec3()
  local updateAccumulator = 0
  local simAccumulator = 0
  -- Refilled every frame by advanceWalkAwayTimers; returned after the iteration, not during it.
  local expiredLoaners = {}

  -- Return -------------------------------------------------------------------------------------------

  -- A damaged loaner costs reputation unless it is police equipment, which expects pursuit damage. The issuing organization is identified so the exemption also survives clock-out and reloading.
  local function damageFineApplies(inventoryId, vehInfo, record)
    local owningOrg = vehInfo.owningOrganization
    local policeLoaner = (record.isCompany or record.isWork) and inputs.facilityRole.isPoliceOrganizationId(owningOrg)
    local needsRepair = overhaul_career_repair_insurance
      and overhaul_career_repair_insurance.inventoryVehNeedsRepair(inventoryId)
    return needsRepair and owningOrg and not policeLoaner and (record.isWork or record.isCompany or record.isRental)
  end

  local function chargeDamagedReturn(inventoryId, owningOrg, record)
    local eventValue = overhaul_career_progression_reputation.getValueForEvent("returnLoanerDamaged", owningOrg)
    if record.isRental then
      eventValue = math.floor((eventValue or DEFAULT_DAMAGE_REPUTATION_EVENT) * RENTAL_DAMAGE_REPUTATION_SHARE)
    end
    local fine = {}
    fine[owningOrg .. "Reputation"] = eventValue
    overhaul_career_economy_playerAttributes.addAttributes(fine, {tags = {"fine"}, label = "ui.career.attributeLog.loanerDamagedReputationCost"})
    guihooks.trigger("toastrMsg", {
      type = "warning",
      label = "loanReturnedDamaged",
      title = _tr("ui.career.loaner.toast.returnedDamaged.title"),
      msg = _tr("ui.career.loaner.toast.returnedDamaged.message")
    })
    local employment = overhaul_career_work_employment
    if employment and (record.isCompany or record.isRental) then
      employment.onIssuedVehicleReturnedDamaged(inventoryId)
    end
  end

  -- Removes one loaner from the inventory, after settling its rental and charging any damage fine.
  local function returnVehicleActual(inventoryId)
    local delivery = overhaul_career_logistics_general
    if delivery and not delivery.canRemoveLogisticsVehicle(inventoryId) then return false end
    local vehInfo = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if not vehInfo then
      loanerState.walkAwayTimers[inventoryId] = nil
      return
    end
    billing.settleRentalOnReturn(vehInfo)
    local record = issued.forVehicle(vehInfo) or {}
    local brokerRentalId = vehInfo.brokerRentalId
    local owningOrg = vehInfo.owningOrganization
    if damageFineApplies(inventoryId, vehInfo, record) then
      chargeDamagedReturn(inventoryId, owningOrg, record)
    end
    overhaul_career_garage_inventory.removeVehicle(inventoryId)
    if record.isCompany then
      local employment = overhaul_career_work_employment
      if employment then
        employment.onIssuedVehicleReturned(inventoryId)
      end
    end
    local broker = overhaul_career_logistics_broker
    if brokerRentalId and broker then
      broker.onRentalVehicleReturned(brokerRentalId)
    end
  end

  local function returnVehicle(inventoryId, callback)
    local delivery = overhaul_career_logistics_general
    if delivery and not delivery.canRemoveLogisticsVehicle(inventoryId) then
      if callback then callback(false) end
      return false
    end
    if overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) then
      overhaul_career_garage_inventory.updatePartConditions(nil, inventoryId, function()
        if returnVehicleActual(inventoryId) == false then
          if callback then callback(false) end
          return
        end
        offers.unmarkAllForSpawning()
        if callback then callback() end
      end)
    else
      if returnVehicleActual(inventoryId) == false then
        if callback then callback(false) end
        return false
      end
      offers.unmarkAllForSpawning()
      if callback then callback() end
    end
  end

  local function returnVehicles(inventoryIds, callback)
    local pendingReturns = #(inventoryIds or {})
    if pendingReturns == 0 then
      if callback then callback() end
      return
    end
    local hasFailedReturn = false
    local function finishOneReturn(returned)
      if returned == false then hasFailedReturn = true end
      pendingReturns = pendingReturns - 1
      if pendingReturns == 0 and callback then
        if hasFailedReturn then callback(false) else callback() end
      end
    end
    for _, inventoryId in ipairs(inventoryIds) do
      returnVehicle(inventoryId, callback and finishOneReturn or nil)
    end
  end

  -- Steps out of a company vehicle the player is still sitting in, so the walk-away rules apply.
  local function stepOutIfInCompanyVehicle()
    local vehId = be:getPlayerVehicleID(0)
    if not vehId or vehId < 0 then return end
    local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
    local vehicleInfo = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId]
    local record = issued.forVehicle(vehicleInfo)
    if not (record and record.isCompany) then return end
    spawn.preventPlayerSpawning = nil
    gameplay_walk.setWalkingMode(true, nil, nil, true)
  end

  local function returnAllCompanyVehicles()
    stepOutIfInCompanyVehicle()
    local companyVehicleIds = {}
    for inventoryId, vehicleInfo in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
      local record = issued.forVehicle(vehicleInfo)
      if record and record.isCompany then
        table.insert(companyVehicleIds, inventoryId)
      end
    end
    returnVehicles(companyVehicleIds)
    return #companyVehicleIds
  end

  -- Lists ------------------------------------------------------------------------------------------

  local function getLoanedVehicles()
    local result = {}
    for _, vehInfo in pairs(overhaul_career_garage_inventory.getVehicles()) do
      if vehInfo.owningOrganization then
        local veh = deepcopy(vehInfo)
        local thumbnailOk, thumbnail = pcall(overhaul_career_garage_inventory.getVehicleThumbnail, veh.id)
        veh.thumbnail = thumbnailOk and thumbnail or nil
        table.insert(result, veh)
      end
    end
    return result
  end

  local function getLoanedVehiclesByOrg(organizationId)
    local result = {}
    for _, vehInfo in ipairs(getLoanedVehicles()) do
      if organizationId == vehInfo.owningOrganization then
        table.insert(result, vehInfo)
      end
    end
    return result
  end

  -- Walk-away --------------------------------------------------------------------------------------

  -- A work or rental loaner that the player has driven past the walk-away radius starts its countdown.
  local function startWalkAwayTimers(vehicles, inventoryIdToVehId)
    for inventoryId, vehInfo in pairs(vehicles) do
      local record = issued.forVehicle(vehInfo)
      if not vehInfo.brokerRentalId and record and (record.isWork or record.isRental)
          and not loanerState.walkAwayTimers[inventoryId] then
        local vehId = inventoryIdToVehId[inventoryId]
        local vehObj = vehId and be:getObjectByID(vehId) or nil
        if vehObj then
          vehiclePosition:set(vehObj:getPosition())
          if playerPosition:squaredDistance(vehiclePosition) > walkAwayRadiusSquared then
            ui_message(core_locales.contextTranslate("ui.career.loaner.message.walkAwayInitial", {seconds = walkAway.timeLimitSeconds}), 5, "loanedVehicleTime")
            loanerState.walkAwayTimers[inventoryId] = {time = walkAway.timeLimitSeconds}
          end
        end
      end
    end
  end

  -- Counts every timer down, warns once near the end, and queues the expired loaners for return.
  local function advanceWalkAwayTimers(simElapsed, vehicles, inventoryIdToVehId)
    table.clear(expiredLoaners)
    for inventoryId, timer in pairs(loanerState.walkAwayTimers) do
      if not vehicles[inventoryId] then
        loanerState.walkAwayTimers[inventoryId] = nil
      elseif not timer.returning then
        local vehId = inventoryIdToVehId[inventoryId]
        local vehObj = vehId and be:getObjectByID(vehId) or nil
        if vehObj then
          vehiclePosition:set(vehObj:getPosition())
          if playerPosition:squaredDistance(vehiclePosition) < comeBackRadiusSquared then
            loanerState.walkAwayTimers[inventoryId] = nil
          else
            timer.time = timer.time - simElapsed
            if timer.time < 0 then
              -- removeVehicle runs asynchronously behind a part condition update, so latch the entry rather than calling returnVehicle again on every tick until the inventory finally drops it.
              timer.returning = true
              table.insert(expiredLoaners, inventoryId)
            elseif not timer.warningShown and timer.time < walkAway.warningTimeSeconds then
              ui_message(core_locales.contextTranslate("ui.career.loaner.message.walkAwayWarning", {seconds = walkAway.warningTimeSeconds}), 5, "loanedVehicleTime")
              timer.warningShown = true
            end
          end
        end
      end
    end
  end

  -- Per frame -------------------------------------------------------------------------------------

  local function onUpdate(dtReal, dtSim)
    simAccumulator = simAccumulator + (tonumber(dtSim) or 0)
    updateAccumulator = updateAccumulator + (tonumber(dtReal) or 0)
    if loanerState.spawnBlocked then
      inputs.spawning.tickBlocked(dtSim)
    end
    -- The walk-away watch only has to notice a 100 m walk-away, so it runs on a fixed cadence rather than once per rendered frame. dtSim is banked across skipped frames so the countdown runs at the same rate.
    if updateAccumulator < UPDATE_INTERVAL_SECONDS then return end
    local simElapsed = simAccumulator
    updateAccumulator = 0
    simAccumulator = 0

    if simElapsed > 0 and overhaul_career_garage_inventory then
      for _, vehInfo in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
        billing.billWholeRentalHours(vehInfo)
      end
    end

    local playerVehId = be:getPlayerVehicleID(0)
    local playerVeh = playerVehId and playerVehId >= 0 and be:getObjectByID(playerVehId) or nil
    if not playerVeh then return end
    playerPosition:set(playerVeh:getPosition())

    local vehicles = overhaul_career_garage_inventory.getVehicles()
    local inventoryIdToVehId = overhaul_career_garage_inventory.getMapInventoryIdToVehId()
    startWalkAwayTimers(vehicles, inventoryIdToVehId)
    advanceWalkAwayTimers(simElapsed, vehicles, inventoryIdToVehId)

    -- returnVehicle mutates the inventory, so it only runs once iteration is done.
    for _, inventoryId in ipairs(expiredLoaners) do
      returnVehicle(inventoryId)
    end
  end

  -- Career lifecycle -------------------------------------------------------------------------------

  -- Work loans from a hourly-rental organization become rentals while the career is active.
  local function onOverhaulActive(active)
    table.clear(loanerState.walkAwayTimers)
    table.clear(expiredLoaners)
    updateAccumulator = 0
    simAccumulator = 0
    if active and overhaul_career_garage_inventory then
      for _, vehInfo in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
        local record = issued.forVehicle(vehInfo)
        if record and record.isWork and vehInfo.owningOrganization then
          local organization = overhaul_world_organizations.getOrganization(vehInfo.owningOrganization)
          if offers.usesIndependentHourlyRental(organization) then
            vehInfo.loanType = "rental"
            vehInfo.rentalHourlyRate = vehInfo.rentalHourlyRate or offers.getHourlyRateForOffer(vehInfo)
            billing.initRentalBilling(vehInfo)
          end
        end
      end
    end
  end

  return {
    returnVehicle = returnVehicle,
    returnVehicles = returnVehicles,
    returnAllCompanyVehicles = returnAllCompanyVehicles,
    stepOutIfInCompanyVehicle = stepOutIfInCompanyVehicle,
    getLoanedVehicles = getLoanedVehicles,
    getLoanedVehiclesByOrg = getLoanedVehiclesByOrg,
    onUpdate = onUpdate,
    onOverhaulActive = onOverhaulActive,
  }
end

return returns
