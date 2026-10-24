-- Personal purchases, reward grants and temporary vehicle spawning for one shopping instance.
-- Read listing placement and freight pickup, purchase settlement, fleet spawn, then reward grants.
local M = {}

function M.new(inputs)
  local service = {}
  local dependencies = {}
  local state = inputs.state
  local owner = inputs.owner

  -- Private listings park at the spot chosen in updateVehicleList; the taxi and route marker point there.
  function service.moveVehicleToListingSpot(vehObj, vehicleInfo)
    if not vehObj or not vehicleInfo or not vehicleInfo.parkingSpotName then return false end
    local parkingData = overhaul_integration_services_parking.getParkingSpots()
    local spot = parkingData and parkingData.byName and parkingData.byName[vehicleInfo.parkingSpotName]
    if not spot then
      log("D", "Career", "Listing parking spot '" .. tostring(vehicleInfo.parkingSpotName) .. "' not found")
      return false
    end
    spot:moveResetVehicleTo(vehObj:getID(), nil, nil, nil, nil, true)
    return true
  end

  -- Private sellers have no facility, so getDealership("private") is nil; leave the car where it spawned.
  service.moveVehicleToDealership = function(vehObj, dealershipId, useFreightPickup)
    if not vehObj or not dealershipId then return false end
    local dealership = dependencies.getDealershipForSellerId(dealershipId)
    if not dealership then
      log("D", "Career", "No dealership facility for '" .. tostring(dealershipId) .. "'; leaving vehicle at spawn")
      return false
    end
    if useFreightPickup and type(dealership.freightPickupSpotNames) == "table" then
      dealership = deepcopy(dealership)
      dealership.parkingSpotNames = dealership.freightPickupSpotNames
    end
    local parkingSpots = overhaul_world_facilities.getParkingSpotsForFacility(dealership)
    if not parkingSpots or not next(parkingSpots) then return false end
    local parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(vehObj:getID(), parkingSpots)
    if not parkingSpot then return false end
    parkingSpot:moveResetVehicleTo(vehObj:getID(), nil, nil, nil, nil, true)
    return true
  end

  service.moveVehicleToRewardTransform = function(vehObj, transform)
    if not vehObj or type(transform) ~= "table" then return end
    if require("overhaul/lib/vehicles/placement").place(vehObj, transform) then return end

    local pos = transform.pos or transform.position
    if not pos then return end

    local rot = transform.rot or transform.rotation or {}
    local px = tonumber(pos.x or pos[1])
    local py = tonumber(pos.y or pos[2])
    local pz = tonumber(pos.z or pos[3])
    if not px or not py or not pz then return end

    local qx = tonumber(rot.x or rot[1]) or 0
    local qy = tonumber(rot.y or rot[2]) or 0
    local qz = tonumber(rot.z or rot[3]) or 0
    local qw = tonumber(rot.w or rot[4]) or 1
    local rewardRot = quat(qx, qy, qz, qw)
    local safeTeleportRot = quat(0, 0, -1, 0) * rewardRot
    spawn.safeTeleport(vehObj, vec3(px, py, pz), safeTeleportRot, false, nil, false, true, false)
  end

  service.getConfigKeyFromPath = function(configPath)
    if type(configPath) ~= "string" then return nil end
    local normalized = configPath:gsub("\\", "/")
    local key = normalized:match("/configurations/([^/]+)%.pc$")
    if key then return key end
    return normalized:match("/([^/]+)%.pc$")
  end

  service.applyRandomPaintToSpawnOptions = function(options, modelKey, configPath)
    if not options or not modelKey then return nil end

    local paintResult = core_vehiclePaints.getRandomPaints(modelKey, service.getConfigKeyFromPath(configPath))
    if type(paintResult) ~= "table" then return nil end

    local modelData = core_vehicles.getModel(modelKey)
    local modelPaints = modelData and modelData.model and modelData.model.paints
    if type(modelPaints) ~= "table" then return nil end

    local paintNames = {
      paintResult.paintName1,
      paintResult.paintName2 or paintResult.paintName1,
      paintResult.paintName3 or paintResult.paintName2 or paintResult.paintName1
    }
    if not paintNames[1] or not modelPaints[paintNames[1]] then return nil end

    options.paintName = paintNames[1]
    options.paintName2 = paintNames[2]
    options.paintName3 = paintNames[3]
    options.paint = deepcopy(modelPaints[paintNames[1]])
    options.paint2 = paintNames[2] and modelPaints[paintNames[2]] and deepcopy(modelPaints[paintNames[2]]) or nil
    options.paint3 = paintNames[3] and modelPaints[paintNames[3]] and deepcopy(modelPaints[paintNames[3]]) or nil

    if type(configPath) == "string" then
      local cfg = jsonReadFile(configPath)
      if type(cfg) == "table" and cfg.format ~= 4 then
        cfg = deepcopy(cfg)
        cfg.partConfigFilename = configPath
        cfg.colors = nil
        local paints = type(cfg.paints) == "table" and deepcopy(cfg.paints) or {}
        paints[1] = deepcopy(options.paint)
        if options.paint2 then paints[2] = deepcopy(options.paint2) end
        if options.paint3 then paints[3] = deepcopy(options.paint3) end
        cfg.paints = paints
        options.config = cfg
      end
    end

    return paintNames
  end

  service.applyRandomPaintToSpawnedVehicle = function(vehId, modelKey, paintNames)
    if not vehId or type(paintNames) ~= "table" or not paintNames[1] then return end

    core_vehicle_manager.setVehiclePaintsNames(vehId, paintNames)

    local vehicleData = core_vehicle_manager.getVehicleData(vehId)
    if not vehicleData or type(vehicleData.config) ~= "table" then return end

    local modelData = modelKey and core_vehicles.getModel(modelKey) or nil
    if not modelData and vehicleData.ioCtx and vehicleData.ioCtx.modelKey then
      modelData = core_vehicles.getModel(vehicleData.ioCtx.modelKey)
    end
    local modelPaints = modelData and modelData.model and modelData.model.paints
    if type(modelPaints) ~= "table" then return end

    local config = vehicleData.config
    config.colors = nil
    local paints = type(config.paints) == "table" and deepcopy(config.paints) or {}
    for i, paintName in ipairs(paintNames) do
      if paintName and modelPaints[paintName] then
        paints[i] = deepcopy(modelPaints[paintName])
      end
    end
    config.paints = paints
    config.paintName = paintNames[1]
    config.paintName2 = paintNames[2]
    config.paintName3 = paintNames[3]
  end

  -- spawnFinishedCallbackName: vehicle callback id (overhaul/lib/vehicles/callbacks; e.g. shopVehicleSpawnFinished adds personal inventory).
  service.spawnShopVehicleInternal = function(vehicleInfo, dealershipToMoveTo, spawnFinishedCallbackName, rewardTransform, randomPaint, useFreightPickup, callbackToken)
    local spawnOptions = {}
    spawnOptions.config = vehicleInfo.key
    spawnOptions.autoEnterVehicle = false
    if rewardTransform then
      local airPos = require("overhaul/lib/vehicles/placement").airSpawnPos(rewardTransform)
      if airPos then
        spawnOptions.pos = airPos
        spawnOptions.safeSpawn = false
        spawnOptions.cling = false
      end
    end
    local randomPaintNames
    if randomPaint then
      randomPaintNames = service.applyRandomPaintToSpawnOptions(spawnOptions, vehicleInfo.model_key, vehicleInfo.key)
    end
    local newVeh = core_vehicles.spawnNewVehicle(vehicleInfo.model_key, spawnOptions)
    if not newVeh then
      log("E", "Career", "Failed to spawn shop vehicle " .. tostring(vehicleInfo.model_key) .. " / " .. tostring(vehicleInfo.key))
      return nil
    end
    if rewardTransform then
      service.moveVehicleToRewardTransform(newVeh, rewardTransform)
    elseif dealershipToMoveTo then
      service.moveVehicleToDealership(newVeh, dealershipToMoveTo, useFreightPickup)
    else
      -- no dealership lot: put it on the listing's own parking spot so it is where the map said
      service.moveVehicleToListingSpot(newVeh, vehicleInfo)
    end
    core_vehicleBridge.executeAction(newVeh, 'setIgnitionLevel', 0)

    local callbackArgs = string.format("%d%s", newVeh:getID(), callbackToken and ("," .. string.format("%q", callbackToken)) or "")
    local requestId = require('overhaul/lib/vehicles/callbacks').open(spawnFinishedCallbackName, {owner = 'vehicleShopping', timeout = false})
    newVeh:queueLuaCommand(string.format(
      "partCondition.initConditions(nil, %d, nil, %f) obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(%d, %q, %q))",
      vehicleInfo.wearMileage or vehicleInfo.Mileage,
      dependencies.getVisualValueFromMileage(vehicleInfo.wearMileage or vehicleInfo.Mileage),
      requestId, spawnFinishedCallbackName, callbackArgs))
    return newVeh, randomPaintNames
  end

  service.spawnVehicle = function(vehicleInfo, dealershipToMoveTo, useFreightPickup)
    if state.personalPurchaseAttempt then return nil end
    local attempt = {token = Engine.generateUUID(), purchase = deepcopy(state.purchaseData),
      followUp = deepcopy(state.spawnFollowUpActions), elapsed = 0}
    attempt.saveHold = require("overhaul/lib/save/store").hold(owner, "vehicle purchase")
    state.personalPurchaseAttempt = attempt
    local newVeh = service.spawnShopVehicleInternal(vehicleInfo, dealershipToMoveTo, "shopVehicleSpawnFinished", nil, nil, useFreightPickup, attempt.token)
    if not newVeh then
      attempt.saveHold.release()
      state.personalPurchaseAttempt = nil
      guihooks.trigger("toastrMsg", {
        type = "error",
        title = _tr("ui.career.inspectVehicle.message.purchaseFailed")
      })
      return nil
    end
    attempt.vehId = newVeh:getID()
    return newVeh
  end

  -- The shopping attempt owns the reservation until inventory takes ownership.
  -- Its callback can exclude its token while registering that same vehicle.
  function service.getPendingInventorySlotCount(excludedToken, garageId, includeExempt)
    local attempt = state.personalPurchaseAttempt
    if not attempt or attempt.token == excludedToken then return 0 end
    if garageId and (not attempt.followUp or attempt.followUp.targetGarageId ~= garageId) then return 0 end
    -- Disposal checks protect every vehicle referencing the garage, even storage exemptions.
    if includeExempt then return 1 end
    local purchase = attempt.purchase
    if purchase.vehicleInfo.takesNoInventorySpace then return 0 end
    local tradeIn = purchase.tradeInVehicleInfo
    local replaced = tradeIn and overhaul_career_garage_inventory.getVehicles()[tradeIn.id]
    if replaced and replaced.owned and overhaul_career_garage_garageManager.vehicleUsesGarageCapacity(replaced, garageId) then return 0 end
    return 1
  end

  -- Racing team fleet drive-in: world vehicle only until business inventory takes ownership (no personal addVehicle).
  service.rtFleetSpawnVehicle = function(vehicleInfo, dealershipToMoveTo)
    return service.spawnShopVehicleInternal(vehicleInfo, dealershipToMoveTo, "fleetVehicleSpawnFinished")
  end

  service.onRacingTeamFleetVehicleSpawnFinished = function(_vehId)
  end

  function service.completeFreightPickup(inventoryId)
    local inventoryVehicle = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if not inventoryVehicle or
      string.find(tostring(inventoryVehicle.location or ""), "freightPickup:", 1, true) ~= 1 then
      return false
    end

    local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
    local vehObj = vehId and getObjectByID(vehId)
    local closestGarage = not inventoryVehicle.freightHomeGarageId and
      overhaul_career_garage_inventory.getClosestOwnedGarageWithSpace(
        vehObj and vehObj:getPosition() or nil) or nil
    if not overhaul_career_garage_inventory.moveVehicleToGarage(
      inventoryId, inventoryVehicle.freightHomeGarageId or (closestGarage and closestGarage.id) or nil) then
      return false
    end
    inventoryVehicle.freightHomeGarageId = nil

    core_groundMarkers.setPath(nil)
    ui_message(
      "Freight pickup complete. Home garage: " ..
        tostring(inventoryVehicle.niceLocation or "Assigned garage") .. ".",
      6, "Vehicle collected", "info")
    if overhaul_career_career.isAutosaveEnabled() then
      overhaul_career_saveSystem.saveCurrent()
    end
    return true
  end

  service.cancelPersonalPurchase = function(skipSave)
    local attempt = state.personalPurchaseAttempt
    if not attempt then return end
    attempt.saveHold.release()
    state.personalPurchaseAttempt = nil
    state.spawnFollowUpActions, state.deleteAddedVehicle = nil, nil
    state.pendingSoldShopIds[attempt.purchase.shopId or attempt.purchase.vehicleInfo.shopId] = nil
    if attempt.paid then
      overhaul_career_economy_playerAttributes.addAttributes({money = attempt.paid},
        {category = "refund", finance = {vehicleName = attempt.purchase.vehicleInfo.niceName},
          tags = {"refund"}, label = "Vehicle delivery refund"})
      local info = attempt.purchase.vehicleInfo
      local found = false
      for _, listing in ipairs(state.vehiclesInShop) do
        if listing.shopId == info.shopId then found = true; break end
      end
      if not found then
        info.markedSold, info.soldViewCounter = nil, nil
        table.insert(state.vehiclesInShop, info)
      end
    end
    local vehObj = attempt.vehId and getObjectByID(attempt.vehId)
    if vehObj then vehObj:delete() end
    if not skipSave then overhaul_career_saveSystem.saveCurrent() end
  end

  service.onVehicleSpawnFinished = function(vehId, token)
    local attempt = state.personalPurchaseAttempt
    if not attempt or attempt.token ~= token or attempt.vehId ~= vehId then return end
    local purchase = attempt.purchase
    local inventoryId = overhaul_career_garage_inventory.addVehicle(vehId, nil, {
      year = purchase and purchase.vehicleInfo and purchase.vehicleInfo.year,
      finalPrice = purchase and (purchase.attemptPrice or purchase.prices.finalPrice),
      replacingInventoryId = purchase.tradeInVehicleInfo and purchase.tradeInVehicleInfo.id,
      purchaseToken = attempt.token,
    })
    if not inventoryId then service.cancelPersonalPurchase(); return end
    -- Payment preceded the spawn callback. Finish its snapshot before releasing the save hold.
    local record = attempt.financeRecord
    if record and record.finance then
      record.finance.vehicleId = tostring(inventoryId)
      record.finance = require("overhaul/lib/finance/metadata").capture({finance = record.finance},
        record.time, record.attributeChange and record.attributeChange.money or 0)
      guihooks.trigger("OverhaulFinancialHistoryChanged")
    end
    attempt.saveHold.release()
    state.personalPurchaseAttempt = nil
    if be:getPlayerVehicleID(0) == vehId then
      -- Sync inventory when the player is already seated, without reloading the vehicle.
      overhaul_career_garage_inventory.enterVehicle(inventoryId, 1)
    end
    dependencies.purchase.settlePurchaseReputation(purchase)
    if state.purchaseData and state.purchaseData.shopId == purchase.shopId then state.purchaseData = nil end
    state.pendingPurchase = {inventoryId = inventoryId, purchaseData = purchase}
    local tradeIn = purchase.tradeInVehicleInfo
    if tradeIn and tradeIn.id and not tradeIn.removedForPurchase then
      tradeIn.removedForPurchase = true
      overhaul_career_garage_inventory.removeVehicle(tradeIn.id)
    end
    state.spawnFollowUpActions = attempt.followUp

    if state.spawnFollowUpActions then
      if state.spawnFollowUpActions.delayAccess then
        overhaul_career_garage_inventory.delayVehicleAccess(inventoryId, state.spawnFollowUpActions.delayAccess, "bought")
      end
      if state.spawnFollowUpActions.licensePlateText then
        overhaul_career_garage_inventory.setLicensePlateText(inventoryId, state.spawnFollowUpActions.licensePlateText)
      end
      if state.spawnFollowUpActions.purchaseVehicleRole then
        overhaul_career_garage_inventory.setVehicleRole(inventoryId, state.spawnFollowUpActions.purchaseVehicleRole)
      end
      if state.spawnFollowUpActions.freightPickup then
        local inventoryVehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
        if inventoryVehicle then
          inventoryVehicle.location = "freightPickup:" .. tostring(state.spawnFollowUpActions.dealershipId or "online")
          inventoryVehicle.niceLocation = "Freight Pickup"
          inventoryVehicle.lastKnownLevel = getCurrentLevelIdentifier()
          inventoryVehicle.freightHomeGarageId = state.spawnFollowUpActions.targetGarageId
        end
        local freightVehicle = getObjectByID(vehId)
        if freightVehicle then
          core_groundMarkers.setPath(freightVehicle:getPosition())
          overhaul_career_police_playerDriving.showPosition(freightVehicle:getPosition())
        end
        ui_message("Order ready at Freight Pickup. It is listed in Vehicle Inventory under Freight Pickup, and a route has been set.", 10,
          "Freight order ready", "info")
      else
        overhaul_career_garage_inventory.moveVehicleToGarage(inventoryId, state.spawnFollowUpActions.targetGarageId)
      end
      state.spawnFollowUpActions = nil
    end
  end

  service.onRewardVehicleSpawnFinished = function(vehId, token)
    local data = state.rewardVehicleGrantData
    if not data or data.token ~= token or data.spawnedVehId ~= vehId then return end

    if data.randomPaintNames then
      service.applyRandomPaintToSpawnedVehicle(vehId, data.vehicleInfo and data.vehicleInfo.model_key, data.randomPaintNames)
    end

    local addOptions = { owned = true, year = data.vehicleInfo and data.vehicleInfo.year }
    if data.ignoreGarageLimit then
      addOptions.takesNoInventorySpace = true
    end
    local inventoryId = overhaul_career_garage_inventory.addVehicle(vehId, nil, addOptions)
    if not inventoryId then return end

    local inventoryVehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if inventoryVehicle then
      inventoryVehicle.rewardGrantId = data.rewardId
      local vehicleData = core_vehicle_manager.getVehicleData(vehId)
      if vehicleData and type(vehicleData.config) == "table" then
        inventoryVehicle.config = deepcopy(vehicleData.config)
      end
      inventoryVehicle.mileage = data.vehicleInfo and data.vehicleInfo.Mileage or inventoryVehicle.mileage or 0
      inventoryVehicle.purchasePrice = 0
      inventoryVehicle.rewardSource = data.source or "Reward"
    end
    table.remove(state.rewardVehicleGrants, 1)
    state.rewardVehicleGrantData = nil

    -- Reward grants are not dealership purchases; start uninsured like car-meet buys.
    extensions.hook("onOverhaulVehicleAddedToInventory", {
      inventoryId = inventoryId,
      vehicleInfo = data.vehicleInfo,
      purchaseData = {insuranceId = -1},
    })

    local vehObj = getObjectByID(vehId)
    if vehObj then
      vehObj:queueLuaCommand('ai.setMode("disabled")')
      vehObj:queueLuaCommand('electrics.setIgnitionLevel(0)')
      vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
      vehObj:queueLuaCommand('if electrics.setLightsState then electrics.setLightsState(0) end')
      vehObj:queueLuaCommand('if electrics.set_warn_signal then electrics.set_warn_signal(0) end')
    end

    if overhaul_career_career.isAutosaveEnabled() then
      overhaul_career_saveSystem.saveCurrent()
    end
  end

  service.processRewardVehicleGrants = function(dt)
    local active = state.rewardVehicleGrantData
    if active then
      active.elapsed = (active.elapsed or 0) + math.max(dt or 0, 0)
      if active.elapsed < 30 then return end
      local vehObj = active.spawnedVehId and getObjectByID(active.spawnedVehId)
      if vehObj then vehObj:delete() end
      active.token, active.spawnedVehId, active.elapsed = nil, nil, nil
      state.rewardVehicleGrantData = nil
      table.remove(state.rewardVehicleGrants, 1)
      table.insert(state.rewardVehicleGrants, active)
    end
    local data = state.rewardVehicleGrants[1]
    if not data then return end
    for _, vehicle in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
      if vehicle.rewardGrantId == data.rewardId then
        table.remove(state.rewardVehicleGrants, 1)
        return
      end
    end
    data.token, data.elapsed = Engine.generateUUID(), 0
    state.rewardVehicleGrantData = data
    local rewardVeh, randomPaintNames = service.spawnShopVehicleInternal(data.vehicleInfo, nil,
      "rewardVehicleSpawnFinished", data.spawnTransform, data.randomPaint, nil, data.token)
    if rewardVeh then
      data.spawnedVehId, data.randomPaintNames = rewardVeh:getID(), randomPaintNames
    end
  end

  service.grantRewardVehicle = function(vehicleInfo, source, options)
    if not vehicleInfo or not vehicleInfo.model_key or not vehicleInfo.key then return false end
    options = options or {}
    if not options.ignoreGarageLimit and not dependencies.purchase.canPurchaseCarMeetVehicle(true) then return false end
    table.insert(state.rewardVehicleGrants, {
      rewardId = Engine.generateUUID(),
      vehicleInfo = deepcopy(vehicleInfo),
      source = source or "Reward",
      ignoreGarageLimit = options.ignoreGarageLimit == true,
      spawnTransform = options.spawnTransform,
      randomPaint = options.randomPaint == true
    })
    service.processRewardVehicleGrants(0)
    return true
  end

  function service.bindServices(bindings)
    assert(type(bindings.getDealershipForSellerId) == "function", "spawn requires getDealershipForSellerId")
    assert(type(bindings.getVisualValueFromMileage) == "function", "spawn requires getVisualValueFromMileage")
    assert(type(bindings.purchase.canPurchaseCarMeetVehicle) == "function", "spawn requires purchase.canPurchaseCarMeetVehicle")
    assert(type(bindings.purchase.settlePurchaseReputation) == "function", "spawn requires purchase.settlePurchaseReputation")
    dependencies = bindings
  end
  return service
end

return M
