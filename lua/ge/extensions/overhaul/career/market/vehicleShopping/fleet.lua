-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Pending business-fleet deliveries, recovery and refunds for one shopping instance.
-- Read capacity and garage helpers, storage and refund operations, then pending-delivery processing.
local M = {}

function M.new(inputs)
  local service = {}
  local dependencies = {}
  local state = inputs.state

  local function businessManager() return overhaul_career_business_manager end

  service.rtFleetCap = function(bid)
    local manager = businessManager()
    local obj = manager and manager.getBusinessObject(state.fleetBusinessType)
    if obj and obj.getMaxPulledOutVehicles then
      return tonumber(obj.getMaxPulledOutVehicles(bid)) or 3
    end
    if obj and obj.getMaxActiveJobs then
      return tonumber(obj.getMaxActiveJobs(bid)) or 3
    end
    return 3
  end

  service.getRacingTeamGarageZones = function(businessId, businessType)
    local inv = overhaul_career_business_fleet
    if not inv or not inv.getBusinessGarage then return nil end
    local garage = inv.getBusinessGarage(businessType or state.fleetBusinessType, businessId)
    if not garage or not garage.sitesFile then return nil end
    local sites = gameplay_sites_sitesManager.loadSites(garage.sitesFile)
    return sites and sites.zones or nil
  end

  service.isVehicleInRacingTeamGarageZone = function(businessId, vehId, businessType)
    if not businessId or not vehId then return false end
    local vehObj = be:getObjectByID(vehId)
    if not vehObj then return false end
    local pos = vehObj:getPosition()
    if not pos then return false end
    local zones = service.getRacingTeamGarageZones(businessId, businessType)
    if not zones or not zones.sorted then return false end
    for _, zone in ipairs(zones.sorted or {}) do
      if zone and zone.containsPoint2D and zone:containsPoint2D(pos) then
        return true
      end
    end
    return false
  end

  service.getRacingTeamDeliveryDelaySeconds = function(businessId, vehicleInfo, businessType)
    if not vehicleInfo or not vehicleInfo.pos then
      return 1
    end
    local inv = overhaul_career_business_fleet
    if not inv or not inv.getBusinessGarage then
      return 1
    end
    local garage = inv.getBusinessGarage(businessType or state.fleetBusinessType, businessId)
    if not garage then
      return 1
    end
    local garagePos = overhaul_world_facilities.getAverageDoorPositionForFacility(garage)
    if not garagePos then
      return 1
    end
    return dependencies.getDeliveryDelay(vehicleInfo.pos:distance(garagePos))
  end

  service.storeRacingTeamFleetVehicleFromPending = function(businessId, pending)
    local inv = overhaul_career_business_fleet
    if not inv or not inv.storeVehicle then
      return false
    end
    if pending.fleetVehicleId then return true, pending.fleetVehicleId end
    pending.purchaseId = pending.purchaseId or Engine.generateUUID()
    for _, vehicle in ipairs(inv.getBusinessVehicles and inv.getBusinessVehicles(businessId) or {}) do
      if vehicle.shopPurchaseId == pending.purchaseId then
        pending.fleetVehicleId = vehicle.vehicleId
        return true, vehicle.vehicleId
      end
    end
    local ok, vehicleId = inv.storeVehicle(businessId, {
      shopPurchaseId = pending.purchaseId,
      vehicleConfig = {
        model_key = pending.model_key,
        key = pending.key
      },
      mileage = pending.mileage or 0,
      purchasePrice = pending.purchasePrice or 0
    })
    if not ok then
      return false
    end
    pending.fleetVehicleId = vehicleId
    local manager = businessManager()
    local businessType = pending.businessType or state.fleetBusinessType
    local owner = manager and manager.hasFeature(businessType, "fleetVehicles") and manager.getBusinessModule(businessType)
    if owner and owner.notifyFleetFromShop then
      owner.notifyFleetFromShop(businessId)
    end

    return true, vehicleId
  end

  service.addPendingRacingTeamFleetPurchase = function(businessId, entry)
    local bid = tostring(businessId)
    state.rtPendingFleetPurchases[bid] = state.rtPendingFleetPurchases[bid] or {}
    entry = entry or {}
    entry.businessType = entry.businessType or state.fleetBusinessType
    entry.purchasedEpoch = tonumber(entry.purchasedEpoch) or os.time()
    entry.purchaseId = entry.purchaseId or Engine.generateUUID()
    table.insert(state.rtPendingFleetPurchases[bid], entry)
  end

  -- Returns the paid price of a fleet purchase that will never be delivered.
  service.refundRacingTeamFleetPurchase = function(businessId, pending, toPlayer)
    local amount = tonumber(pending and pending.purchasePrice) or 0
    if amount <= 0 or pending.refunded then return end
    pending.refunded = true
    local label = "Refund: undelivered fleet vehicle"
    if not toPlayer then
      local bank = overhaul_career_economy_bank
      local acct = bank.getBusinessAccount(pending.businessType or state.fleetBusinessType, businessId)
      local accountId = acct and (acct.id or acct.accountId)
      if accountId and bank.rewardToAccount({money = {amount = amount}}, accountId, label, "Fleet purchase refund", require("overhaul/lib/finance/metadata").tag(nil, "refund")) then
        return
      end
    end
    overhaul_career_economy_payment.reward({money = {amount = amount}}, require("overhaul/lib/finance/metadata").tag({label = label, tags = {"refund"}}, "refund"), true)
  end

  -- Only a stored vehicle is announced to the business module, so a failed store is never reported as delivered.
  local function deliverStoredFleetVehicleAtPurchase(businessId, pending, fleetVehicleId)
    local inv = overhaul_career_business_fleet
    if inv and inv.deliverFleetVehicleAtPurchase then
      inv.deliverFleetVehicleAtPurchase(pending.businessType or "racingTeam", businessId, fleetVehicleId)
    end
  end

  -- The recovery window keeps an undeliverable purchase from holding money indefinitely.
  local function settleDueTimerPendingPurchase(businessId, pending, now)
    local stored, fleetVehicleId = service.storeRacingTeamFleetVehicleFromPending(businessId, pending)
    if stored == true then
      if fleetVehicleId then
        deliverStoredFleetVehicleAtPurchase(businessId, pending, fleetVehicleId)
      end
      return true
    end
    pending.firstStoreFailureEpoch = tonumber(pending.firstStoreFailureEpoch) or now
    if now - pending.firstStoreFailureEpoch >= state.rtPendingStoreFailureRefundSec then
      log("W", "Career", "Refunding fleet purchase that could not be delivered: " .. tostring(pending.purchaseId))
      service.refundRacingTeamFleetPurchase(businessId, pending)
      return true
    end
    return false
  end

  local function processTimerPendingPurchase(businessId, pending, now)
    local dueEpoch = tonumber(pending.dueEpoch) or 0
    if dueEpoch > 0 and now >= dueEpoch then
      return settleDueTimerPendingPurchase(businessId, pending, now)
    end
    return false
  end

  local function registerDriveInFleetDelivery(businessId, pending, fleetVehicleId, spawnedVehId)
    local inv = overhaul_career_business_fleet
    if fleetVehicleId and inv and inv.registerFleetVehicleDeliveredDriveIn then
      inv.registerFleetVehicleDeliveredDriveIn(pending.businessType or "racingTeam", businessId, fleetVehicleId, spawnedVehId)
      if inv.requestFleetVehicleStatsRead then
        inv.requestFleetVehicleStatsRead(businessId, fleetVehicleId)
      end
    end
  end

  -- A missing drive-in becomes a timer so the delivery and refund path can eventually settle it.
  local function processDrivePendingPurchase(businessId, pending, now, purchasedEpoch)
    local spawnedVehId = tonumber(pending.spawnedVehId)
    if spawnedVehId and service.isVehicleInRacingTeamGarageZone(businessId, spawnedVehId, pending.businessType) then
      local stored, fleetVehicleId = service.storeRacingTeamFleetVehicleFromPending(businessId, pending)
      if not stored then
        return false
      end
      registerDriveInFleetDelivery(businessId, pending, fleetVehicleId, spawnedVehId)
      return true
    end
    local age = now - purchasedEpoch
    if age >= state.rtPendingDriveStaleSec and not (spawnedVehId and getObjectByID(spawnedVehId)) then
      pending.kind, pending.dueEpoch, pending.spawnedVehId = "timer", now, nil
    end
    return false
  end

  -- Settled entries leave the pending list so delivery or refund cannot repeat.
  local function processPendingFleetPurchase(businessId, pending, now)
    local purchasedEpoch = tonumber(pending and pending.purchasedEpoch) or now
    if pending.kind == "timer" then
      return processTimerPendingPurchase(businessId, pending, now)
    elseif pending.kind == "drive" then
      return processDrivePendingPurchase(businessId, pending, now, purchasedEpoch)
    end
    return false
  end

  local function settlePendingFleetList(bid, entries, now)
    local keep = {}
    for _, pending in ipairs(entries) do
      if not processPendingFleetPurchase(bid, pending, now) then
        table.insert(keep, pending)
      end
    end
    if #keep > 0 then
      state.rtPendingFleetPurchases[bid] = keep
    else
      state.rtPendingFleetPurchases[bid] = nil
    end
  end

  service.processPendingRacingTeamFleetPurchases = function()
    if state.rtPendingFleetProcessing or not next(state.rtPendingFleetPurchases) then
      return
    end
    state.rtPendingFleetProcessing = true
    local ok, err = pcall(function()
      local now = os.time()
      for bid, entries in pairs(state.rtPendingFleetPurchases) do
        if type(entries) == "table" then
          settlePendingFleetList(bid, entries, now)
        end
      end
    end)
    state.rtPendingFleetProcessing = false
    if not ok then
      log("E", "Career", "processPendingRacingTeamFleetPurchases failed: " .. tostring(err))
    end
  end

  service.clearPendingRacingTeamFleetPurchases = function(businessId)
    if businessId == nil then return end
    local bid = tostring(tonumber(businessId) or businessId)
    -- The business account is closed with the business, so undelivered purchases go back to the player.
    for _, pending in ipairs(state.rtPendingFleetPurchases[bid] or {}) do
      if not pending.fleetVehicleId then
        service.refundRacingTeamFleetPurchase(bid, pending, true)
      end
    end
    state.rtPendingFleetPurchases[bid] = nil
  end

  service.getPendingRacingTeamFleetPurchases = function(businessId)
    -- Ensure UI never sees stale pending entries after delivery.
    service.processPendingRacingTeamFleetPurchases()
    if businessId == nil then
      return {}
    end
    local bid = tostring(tonumber(businessId) or businessId)
    local list = state.rtPendingFleetPurchases[bid]
    if type(list) ~= "table" then
      return {}
    end
    local out = {}
    local now = os.time()
    for i, p in ipairs(list) do
      if type(p) == "table" then
        out[#out + 1] = {
          pendingId = tostring(p.purchasedEpoch or now) .. "_" .. tostring(i),
          kind = p.kind,
          dueEpoch = tonumber(p.dueEpoch),
          secondsRemaining = math.max(0, math.floor((tonumber(p.dueEpoch) or now) - now)),
          model_key = p.model_key,
          key = p.key,
          mileage = p.mileage or 0,
          purchasePrice = p.purchasePrice or 0,
          spawnedVehId = tonumber(p.spawnedVehId),
          purchasedEpoch = tonumber(p.purchasedEpoch) or now
        }
      end
    end
    return out
  end

  function service.bindServices(bindings)
    assert(type(bindings.getDeliveryDelay) == "function", "fleet requires getDeliveryDelay")
    dependencies = bindings
  end
  return service
end

return M
