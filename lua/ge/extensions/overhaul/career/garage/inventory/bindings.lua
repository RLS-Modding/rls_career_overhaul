-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Inventory id <-> vehicle id bindings, adding/removing vehicles and part-condition updates.
-- Acquisition fields are captured before condition replies can arrive.
local bindings = {}

function bindings.new(inputs)
  local garageState = inputs.state
  local M = inputs.M
  local inventoryIdToVehId = inputs.inventoryIdToVehId
  local pendingMaintenanceSeedInventoryIds = inputs.pendingMaintenanceSeedInventoryIds
  local vehicles = inputs.vehicles
  local helpers = {}

  -- Bindings ------------------------------------------------------------------------------------------

  local function assignInventoryIdToVehId(inventoryId, vehId)
    local previousInventoryId = inputs.vehIdToInventoryId[vehId]
    if inputs.vehIdToInventoryId[vehId] then
      inventoryIdToVehId[inputs.vehIdToInventoryId[vehId]] = nil
    end
    inputs.vehIdToInventoryId[vehId] = inventoryId
    inventoryIdToVehId[inventoryId] = vehId
    if extensions and extensions.hook then extensions.hook("onOverhaulInventoryBindingsChanged") end
    if vehicles[inventoryId] then vehicles[inventoryId].lastKnownLevel = getCurrentLevelIdentifier() end
    helpers.bumpGeneration(previousInventoryId)
    helpers.bumpGeneration(inventoryId)
    overhaul_shell_extensionManager.applyCareerVehicleExtensions(be:getObjectByID(vehId))
  end

  local getNumberOfFreeSlots = function(excludedPurchaseToken)
    return overhaul_career_garage_garageManager.getFreeSlots(excludedPurchaseToken)
  end

  local function hasFreeSlot(excludedPurchaseToken)
    return getNumberOfFreeSlots(excludedPurchaseToken) > 0
  end

  -- Vehicle acquisition -------------------------------------------------------------------------------

  local pendingVehicleAddedIds = {}

  local function translatedVehicleName(vehicleData)
    local niceName
    if vehicleData.vdata and vehicleData.vdata.information then
      niceName = vehicleData.vdata.information.name
    end
    local translated = core_locales.translateWithOrWithoutContext(niceName)
    if type(translated) == "string" and translated ~= "" then
      niceName = translated
    end

    return niceName
  end

  local function initializeVehicleRecord(inventoryId, vehicle, vehicleData, options)
    vehicles[inventoryId] = vehicles[inventoryId] or {}
    vehicles[inventoryId].model = vehicle.JBeam or ""
    vehicles[inventoryId].config = vehicleData.config
    vehicles[inventoryId].id = inventoryId
    vehicles[inventoryId].config.licenseName = core_vehicles.getVehicleLicenseText(vehicle)
    vehicles[inventoryId].owned = options.owned
    vehicles[inventoryId].lastKnownLevel = getCurrentLevelIdentifier()
    vehicles[inventoryId].defaultThumbnail = true
    vehicles[inventoryId].finalBuyingPrice = options.finalPrice
    -- Capture acquisition metadata before asynchronous replies; gifts and auctions have no shopping state.
    vehicles[inventoryId].year = tonumber(options.year) or tonumber(vehicles[inventoryId].year)
  end

  local function applyCatalogInformation(inventoryId, vehicle, vehicleData, niceName)
    if vehicle.JBeam and vehicleData.config and vehicleData.config.partConfigFilename then
      local _, configName = path.splitWithoutExt(vehicleData.config.partConfigFilename)
      local baseConfig = core_vehicles.getConfig(vehicle.JBeam, configName)
      local years = baseConfig and (baseConfig.Years or (baseConfig.aggregates and baseConfig.aggregates.Years))
      if not vehicles[inventoryId].year and type(years) == "table" then
        vehicles[inventoryId].year = tonumber(years.max) or tonumber(years.min)
      end
      local catalogProfile = overhaul_career_market_valueCalculator.getVehicleCatalogProfile(vehicle.JBeam, configName, baseConfig)
      vehicles[inventoryId].configBaseValue =
        (catalogProfile and catalogProfile.catalogValue) or baseConfig.Value
      vehicles[inventoryId].takesNoInventorySpace = baseConfig.takesNoInventorySpace

      if type(niceName) ~= "string" or niceName == "" then
        local configInfo = baseConfig or core_vehicles.getConfig(vehicle.JBeam, configName)
        if configInfo then
          local configLabel, brand = configInfo.Name, configInfo.Brand
          configLabel = core_locales.translateWithOrWithoutContext(configLabel)
          brand = core_locales.translateWithOrWithoutContext(brand)
          if type(configLabel) == "string" and configLabel ~= "" then
            if type(brand) == "string" and brand ~= "" then
              niceName = brand .. " " .. configLabel
            else
              niceName = configLabel
            end
          end
        end
      end
    else
      log("D", "", "Couldnt find base value for added vehicle, so using default value")
      vehicles[inventoryId].configBaseValue = 1000
    end

    return niceName
  end

  local function finishVehicleIdentity(inventoryId, vehicle, niceName)
    if type(niceName) ~= "string" or niceName == "" then
      niceName = vehicle.JBeam or "Vehicle"
    end
    vehicles[inventoryId].niceName = niceName
    local currentYear = tonumber(os.date("%Y"))
    vehicles[inventoryId].year = math.min(vehicles[inventoryId].year or currentYear, currentYear)
  end

  local function requestAddedVehicleConditions(inventoryId, vehId, vehicle, vehicleData, options)
    pendingVehicleAddedIds[inventoryId] = true
    local serializedInventoryId = serialize(inventoryId)
    local paintsLua = "nil"
    if type(vehicleData.config.paints) == "table" and vehicleData.config.paints[1] then
      paintsLua = serialize(vehicleData.config.paints)
    end
    if options.skipPartConditionInit then
      vehicle:queueLuaCommand(string.format("obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(%d, 'inventoryPartConditions', %q))", require('overhaul/lib/vehicles/callbacks').open('inventoryPartConditions', {owner = 'inventory', timeout = false}), string.format("%d, %s", vehId, serializedInventoryId)))
    else
      vehicle:queueLuaCommand(string.format("if not partCondition.getConditions() then local paints = %s if paints then v.config.paints = paints end partCondition.initConditions(nil, nil, nil, nil, paints) end obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(%d, 'inventoryPartConditions', %q))", paintsLua, require('overhaul/lib/vehicles/callbacks').open('inventoryPartConditions', {owner = 'inventory', timeout = false}), string.format("%d, %s", vehId, serializedInventoryId)))
    end
  end

  local function awardGarageAchievements(inventoryId)
    local amountOfVehicles = tableSize(vehicles)
    if amountOfVehicles == 1 then
      M.setFavoriteVehicle(inventoryId)
    end
    local amountOfOwnedVehicles = 0
    for _, inventoryVehicle in pairs(vehicles) do
      if inventoryVehicle.owned then
        amountOfOwnedVehicles = amountOfOwnedVehicles + 1
      end
    end
    if amountOfOwnedVehicles >= 3 then
      gameplay_achievement.unlockAchievement("GARAGE_STARTER")
    end
  end

  local function addVehicle(vehId, inventoryId, options)
    options = options or {}
    if options.owned == nil then options.owned = true end

    local vehicle = scenetree.findObjectById(vehId)
    local vehicleData = core_vehicle_manager.getVehicleData(vehId)

    if not vehicle or not vehicleData then return end
    local takesNoInventorySpace = options.takesNoInventorySpace
    if takesNoInventorySpace == nil and vehicle.JBeam and vehicleData.config and vehicleData.config.partConfigFilename then
      local _, configName = path.splitWithoutExt(vehicleData.config.partConfigFilename)
      local baseConfig = core_vehicles.getConfig(vehicle.JBeam, configName)
      takesNoInventorySpace = baseConfig and baseConfig.takesNoInventorySpace
    end
    -- Gifts can arrive before a garage exists, so they bypass capacity and still persist.
    local replacement = options.replacingInventoryId and vehicles[options.replacingInventoryId]
    local replacesOwnedSlot = replacement and replacement.owned
      and overhaul_career_garage_garageManager.vehicleUsesGarageCapacity(replacement)
    if options.owned and not takesNoInventorySpace and not options.starter and not replacesOwnedSlot and not hasFreeSlot(options.purchaseToken) then
      ui_message("No free garage space for another vehicle.", nil, "vehicleInventory")
      return nil
    end

    if not inventoryId then
      inventoryId = 1
      while vehicles[inventoryId] do
        inventoryId = inventoryId + 1
      end
    end
    local niceName = translatedVehicleName(vehicleData)
    initializeVehicleRecord(inventoryId, vehicle, vehicleData, options)
    niceName = applyCatalogInformation(inventoryId, vehicle, vehicleData, niceName)
    finishVehicleIdentity(inventoryId, vehicle, niceName)
    assignInventoryIdToVehId(inventoryId, vehId)
    pendingMaintenanceSeedInventoryIds[inventoryId] = options.owned == true and vehicles[inventoryId].maintenanceState == nil
    requestAddedVehicleConditions(inventoryId, vehId, vehicle, vehicleData, options)
    awardGarageAchievements(inventoryId)
    return inventoryId
  end

  -- Vehicle removal -----------------------------------------------------------------------------------

  local function clearMapCollisionReferences(vehId)
    if not map or not map.objects then return end
    for _, mapObj in pairs(map.objects) do
      if mapObj and mapObj.objectCollisions and mapObj.objectCollisions[vehId] ~= nil then
        mapObj.objectCollisions[vehId] = nil
      end
    end
  end

  local function removeVehicleObject(inventoryId, skipPartConditions)
    local retiringId = inventoryIdToVehId[inventoryId]
    local retiringObject = retiringId and getObjectByID(retiringId)
    -- Traffic cleanup restores every mesh's alpha; damage capture then deletes
    -- asynchronously. Keep the retiring object hidden through both operations.
    if retiringObject then retiringObject:setHidden(true) end
    if garageState.currentVehicle == inventoryId then
      garageState.skipPartConditionsBeforeWalking = true
      garageState.currentVehicle = nil
      gameplay_walk.setWalkingMode(true, nil, nil, true)
    end
    extensions.hook("onOverhaulInventoryPreRemoveVehicleObject", inventoryId, M.getVehicleIdFromInventoryId(inventoryId))
    local vehId = inventoryIdToVehId[inventoryId]
    if vehId then
      -- Clear traffic tracking before deletion so collision checks cannot dereference a removed object.
      if gameplay_traffic then
        pcall(function() gameplay_traffic.removeTraffic(vehId) end)
      end
      clearMapCollisionReferences(vehId)
      local obj = getObjectByID(vehId)
      if obj and not skipPartConditions then
        overhaul_career_repair_damageManager.saveDamageState(inventoryId, nil, true) -- remove vehicle
      elseif obj and skipPartConditions then
        obj:delete()
      end
      inputs.vehIdToInventoryId[vehId] = nil
    end
    inventoryIdToVehId[inventoryId] = nil
    if extensions and extensions.hook then extensions.hook("onOverhaulInventoryBindingsChanged") end
    if M.setTransientBuild then M.setTransientBuild(inventoryId, false) end
    helpers.bumpGeneration(inventoryId)
    helpers.spawnReadiness.removed(inventoryId)
  end

  local function removeVehicle(inventoryId)
    local delivery = overhaul_career_logistics_general
    if not delivery.canRemoveLogisticsVehicle(inventoryId) then return false end
    -- Permanent removal cannot leave a snapshot for the next record that reuses this id.
    overhaul_career_repair_damageManager.discardDamageState(inventoryId)
    if vehicles[inventoryId] then vehicles[inventoryId].mechanismState = nil end
    removeVehicleObject(inventoryId, true)
    vehicles[inventoryId] = nil
    helpers.bumpGeneration(inventoryId)
    extensions.hook("onOverhaulVehicleRemoved", inventoryId)

    if garageState.favoriteVehicle == inventoryId then
      M.setFavoriteVehicle(next(vehicles))
    end
  end

  -- Condition replies ---------------------------------------------------------------------------------

  local function onPartConditionsUpdateFinished(completedInventoryId)
    if completedInventoryId ~= nil and pendingVehicleAddedIds[completedInventoryId] then
      pendingVehicleAddedIds[completedInventoryId] = nil
      -- Temporary contract targets use non-personal ids and must stay out of player-owned part inventory.
      if helpers.isPersonalInventoryId(completedInventoryId) then
        extensions.hook("onOverhaulVehicleAdded", completedInventoryId)
      end
    end
  end

  local function seedInitialMaintenanceStateForVehicle(inventoryId)
    local vehicleData = vehicles[inventoryId]
    if not vehicleData or not pendingMaintenanceSeedInventoryIds[inventoryId] then return false end
    pendingMaintenanceSeedInventoryIds[inventoryId] = nil
    if vehicleData.owned ~= true or vehicleData.maintenanceState ~= nil then return false end

    local mileageMeters = M.setMileage(inventoryId) or 0
    vehicleData.maintenanceState = inputs.maintenanceComputerConfig.buildInitialSnapshotForMileage(mileageMeters, "meters", vehicleData)
    overhaul_vehicles_maintenanceBridge.syncVehicleMaintenance(inventoryId)
    return true
  end

  local function getPartConditionsCallback(partConditions, inventoryId, batchToken)
    if not helpers.partConditionBatches:isLive(batchToken) then return end
    if M.isTransientBuild and M.isTransientBuild(inventoryId) then return end
    if type(partConditions) ~= "table" or not vehicles[inventoryId] then
      onPartConditionsUpdateFinished(inventoryId)
      return
    end
    partConditions = inputs.sanitizeMaintenancePartConditionsForVehicle(vehicles[inventoryId], partConditions)
    vehicles[inventoryId].partConditions = partConditions
    seedInitialMaintenanceStateForVehicle(inventoryId)
    extensions.hook("onOverhaulVehiclePartConditionsChanged", inventoryId)
    onPartConditionsUpdateFinished(inventoryId)
    overhaul_career_parts_partInventory.updatePartConditionsInInventory(inventoryId)
  end

  local function updatePartConditions(vehId, inventoryId, callback, batchToken)
    if M.isTransientBuild and M.isTransientBuild(inventoryId) then
      if callback then callback() end
      return
    end
    if inventoryId and helpers.isVehicleListedForAuction(inventoryId) then
      if callback then callback() end
      return
    end
    local veh
    if vehId then
      veh = getObjectByID(vehId)
    else
      veh = getObjectByID(inventoryIdToVehId[inventoryId])
    end
    if not veh then
      log("E", "", "Couldnt find vehicle object to get part conditions")
      if callback then callback() end
      return
    end

    local requestedVehId = veh:getID()
    local posePending = M and M.isDamageRestorePending and M.isDamageRestorePending(inventoryId)
    core_vehicleBridge.requestValue(
      veh,
      function(res)
        local function finish()
          if not helpers.partConditionBatches:isLive(batchToken) then return end
          if inventoryIdToVehId[inventoryId] ~= requestedVehId then return end
          if M.isTransientBuild and M.isTransientBuild(inventoryId) then
            if callback then callback() end
            return
          end
          local clock = os.clockhp or os.clock
          local started = clock()
          local result = res.result
          if result and result.format == 'overhaul_inventory_state_v1' then
            -- A halfway actuator position must not replace the target a pending arrival still needs.
            if not posePending and not (M and M.isDamageRestorePending and M.isDamageRestorePending(inventoryId)) then
              vehicles[inventoryId].mechanismState = result.mechanismState
            end
            result = result.partConditions
          end
          getPartConditionsCallback(result, inventoryId, batchToken)
          if callback then callback() end
          local elapsed = (clock() - started) * 1000
          if batchToken and elapsed >= 5 then
            log('D', 'inventory', string.format('save frame part_conditions_ms=%.3f inventory_id=%s', elapsed, tostring(inventoryId)))
          end
        end
        if batchToken and helpers.partConditionBatches.deferred[batchToken] then
          overhaul_career_saveSystem.deferSaveWork(finish, nil, true)
        else
          finish()
        end
      end,
      'getOverhaulInventoryVehicleState'
    )
  end

  local function applyPartConditions(inventoryId, vehId)
    local veh = scenetree.findObjectById(vehId or inventoryIdToVehId[inventoryId])
    if not veh then return end
    core_vehicleBridge.executeAction(veh, 'initPartConditions', vehicles[inventoryId].partConditions)
  end

  -- Public API ----------------------------------------------------------------------------------------

  return {
    addVehicle = addVehicle,
    applyPartConditions = applyPartConditions,
    assignInventoryIdToVehId = assignInventoryIdToVehId,
    getNumberOfFreeSlots = getNumberOfFreeSlots,
    getPartConditionsCallback = getPartConditionsCallback,
    hasFreeSlot = hasFreeSlot,
    removeVehicle = removeVehicle,
    removeVehicleObject = removeVehicleObject,
    updatePartConditions = updatePartConditions,
    bindInputs = function(inputs)
      helpers.bumpGeneration = inputs.bumpGeneration
      helpers.spawnReadiness = inputs.spawnReadiness
      helpers.isPersonalInventoryId = inputs.isPersonalInventoryId
      helpers.isVehicleListedForAuction = inputs.isVehicleListedForAuction
      helpers.partConditionBatches = inputs.partConditionBatches
    end,
  }
end

return bindings
