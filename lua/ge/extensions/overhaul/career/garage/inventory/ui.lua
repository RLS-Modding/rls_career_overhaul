-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Inventory UI owns vehicle projections, menu state and retrieval choices.
-- Read in order: garage queries, display data, menu projection, fade callbacks, retrieval and API; inventory.lua owns frame work.
local ui = {}

function ui.new(inputs)
  local garageState = inputs.state
  local M = inputs.M
  local getInventoryMenuGarage = inputs.getInventoryMenuGarage
  local inventoryIdToVehId = inputs.inventoryIdToVehId
  local vehicles = inputs.vehicles
  local helpers = {}

  -- Constants -------------------------------------------------------------------------------------

  local FUEL_TYPE_LABELS = {
    {key = "fuelTank:gasoline", label = "Gasoline"},
    {key = "fuelTank:diesel", label = "Diesel"},
    {key = "fuelTank:electric", label = "Electric"},
  }

  local INDUCTION_TYPE_LABELS = {
    {key = "naturalAspiration", label = "NA"},
    {key = "turbocharger", label = "Turbocharger"},
  }

  local BUTTONS_ENABLED_BY_DEFAULT = {
    "repairEnabled", "sellEnabled", "favoriteEnabled", "storingEnabled", "returnLoanerEnabled",
  }

  -- Inventory rows, chooser actions, the computer hero and phone selling share this projection.
  local VEHICLE_LIST_FIELDS = {
    "id", "owned", "odometer", "location", "niceLocation", "dirtyDate",
    "missingFile", "timeToAccess", "delayReason", "listedForAuction",
    "certifications", "certificationData",
  }

  -- Menu state ------------------------------------------------------------------------------------

  local menuIsOpen
  local buttonsActive = {}
  local chooseButtonsData = {}
  local menuHeader
  local menuBackTarget
  local callbackAfterFade
  local publishedVehicles

  -- Garage queries --------------------------------------------------------------------------------

  local function setPartConditionResetSnapshot(veh, callback)
    core_vehicleBridge.executeAction(veh, 'createPartConditionSnapshot', "beforeReset")
    core_vehicleBridge.executeAction(veh, 'setPartConditionResetSnapshotKey', "beforeReset")
    if callback then
      core_vehicleBridge.requestValue(veh, callback, "ping")
    end
  end

  local function onBigMapActivated()
    if garageState.currentVehicle then
      setPartConditionResetSnapshot(getPlayerVehicle(0))
    end
  end

  local function teleportedFromBigmap()
    if garageState.currentVehicle and overhaul_career_career.isAutosaveEnabled() then
      overhaul_career_saveSystem.saveCurrent()
    end
  end

  local function getLastVehicle()
    return garageState.lastVehicle
  end

  local function getVehicleIdFromInventoryId(inventoryId)
    if inventoryId then
      return inventoryIdToVehId[inventoryId]
    end
  end

  local function getInventoryIdFromVehicleId(vehId)
    if vehId then
      return inputs.vehIdToInventoryId[vehId]
    end
  end

  local function getMapInventoryIdToVehId()
    return inventoryIdToVehId
  end

  local function getCurrentVehicleId()
    return getVehicleIdFromInventoryId(garageState.currentVehicle)
  end

  local function isSeatedInsideOwnedVehicle()
    return garageState.currentVehicle and true or false
  end

  local function vehicleOverlapsZone(veh, zone)
    local vehBB = veh:getWorldBox()
    local vehBBExtents = vehBB:getExtents() * 0.5
    local vehPos = veh:getPosition()
    local zoneExtents = vec3(zone.aabb.xMax - zone.aabb.xMin, zone.aabb.yMax - zone.aabb.yMin, zone.aabb.zMax - zone.aabb.zMin)
    zoneExtents.z = math.min(zoneExtents.z, 10000)
    if not overlapsOBB_OBB(vehBB:getCenter(), inputs.xVec * vehBBExtents.x, inputs.yVec * vehBBExtents.y, inputs.zVec * vehBBExtents.z,
                           zone.center, inputs.xVec * zoneExtents.x/2, inputs.yVec * zoneExtents.y/2, inputs.zVec * zoneExtents.z/2) then
      return false
    end
    for nodeId = 0, veh:getNodeCount() - 1 do
      if zone:containsPoint2D(veh:getNodePosition(nodeId) + vehPos) then
        return true
      end
    end
    return false
  end

  local function getVehiclesInGarage(garage, intersecting)
    if not garage then return {} end
    local zones = overhaul_world_facilities.getZonesForFacility(garage)
    local spawnedVehicles = {}
    local res = {}
    for inventoryId, vehId in pairs(inventoryIdToVehId) do
      spawnedVehicles[inventoryId] = getObjectByID(vehId)
    end
    for _, zone in ipairs(zones) do
      for inventoryId, veh in pairs(spawnedVehicles) do
        if intersecting then
          if vehicleOverlapsZone(veh, zone) then res[inventoryId] = true end
        elseif zone:containsVehicle(veh) then
          res[inventoryId] = true
        end
      end
    end
    return res
  end

  local function removeVehiclesFromGarageExcept(inventoryId)
    local garage = inputs.getClosestGarage()
    local inventoryIdsInGarage = getVehiclesInGarage(garage, true)
    for otherInventoryId, _ in pairs(inventoryIdsInGarage) do
      if otherInventoryId ~= inventoryId then
        local vehInfo = vehicles[otherInventoryId]
        if vehInfo.owned then
          M.removeVehicleObject(otherInventoryId)
          M.switchGarageSpots(otherInventoryId, inventoryId)
        end
      end
    end
  end

  local function getInventoryIdsInClosestGarage(onlyFirst)
    local closestGarage = inputs.getClosestGarage()
    local inventoryIdsInGarage = getVehiclesInGarage(closestGarage, true)
    local inventoryIdsList = {}
    for inventoryId, _ in pairs(inventoryIdsInGarage) do
      table.insert(inventoryIdsList, inventoryId)
    end
    if getPlayerVehicle(0) then
      local playerPos = getPlayerVehicle(0):getPosition()
      table.sort(inventoryIdsList, function(id1, id2)
        local veh1 = getObjectByID(inventoryIdToVehId[id1])
        local veh2 = getObjectByID(inventoryIdToVehId[id2])
        return veh1:getPosition():distance(playerPos) < veh2:getPosition():distance(playerPos)
      end)
    end
    if onlyFirst then
      return next(inventoryIdsInGarage)
    else
      return inventoryIdsList
    end
  end

  local function isVehicleOnSite(inventoryId, garage)
    local vehicle = vehicles[inventoryId]
    if not vehicle or not vehicle.location then
      return
    end
    return vehicle.location == garage.id
  end

  local function isVehicleStoredAtGarage(inventoryId, garageId)
    local vehicle = vehicles[inventoryId]
    return (vehicle and garageId and not inventoryIdToVehId[inventoryId] and
      (vehicle.location == garageId or vehicle.location == nil)) or false
  end

  -- Display data ----------------------------------------------------------------------------------

  local function existingImage(filename)
    if type(filename) == 'string' and filename ~= '' and FS:fileExists(filename) then return filename end
  end

  local function getConfigThumb(configData, model, modelKey)
    local filename = configData and configData.partConfigFilename
    if type(filename) ~= "string" or filename == "" then return nil end
    local directory, configKey = path.splitWithoutExt(filename)
    -- A custom file can share a stock config's basename without being that config.
    local catalogPath = directory:gsub('\\', '/'):gsub('^/', '') == 'vehicles/' .. modelKey .. '/'
    local config = catalogPath and model.configs and model.configs[configKey]
    local preview = config and existingImage(config.preview)
    if preview then return preview end
    -- User-saved configs can have a neighbouring preview without a catalog row.
    if filename:sub(-3) == '.pc' then return existingImage(filename:sub(1, -4) .. '.jpg') end
  end

  local function getVehicleThumbnail(inventoryId)
    if not inventoryId then return end
    local vehicle = vehicles[inventoryId]
    if not vehicle then return end
    -- A saved photo can outlive a config change. All inventory surfaces resolve
    -- the selected config first, rather than presenting that old photo as current.
    local model = core_vehicles.getModel(vehicle.model) or {}
    local vehId = inventoryIdToVehId[inventoryId]
    local live = vehId and core_vehicle_manager.getVehicleData(vehId)
    local configThumb = getConfigThumb(live and live.config or vehicle.config, model, vehicle.model)
    if configThumb then return configThumb end
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if savePath and savePath:sub(1, 1) ~= "/" then
      savePath = "/" .. savePath
    end
    local thumbnailPath = savePath and (savePath .. "/career/vehicles/" .. inventoryId .. ".jpg")
    if not vehicle.defaultThumbnail and existingImage(thumbnailPath) then
      return thumbnailPath
    end
    return model.model and existingImage(model.model.preview)
  end

  -- Known keys get a friendly label; any other key is shown as is.
  local function labelFromFlags(flags, knownLabels)
    for _, known in ipairs(knownLabels) do
      if flags[known.key] then return known.label end
    end
    return next(flags) or "Unknown"
  end

  local function labelDrivetrain(performanceData)
    local frontWheelDrive = performanceData.powertrainLayout.poweredWheelsFront > 0
    local rearWheelDrive = performanceData.powertrainLayout.poweredWheelsRear > 0
    performanceData.drivetrain = frontWheelDrive and rearWheelDrive and "AWD" or frontWheelDrive and "FWD" or rearWheelDrive and "RWD" or "Unknown"
  end

  local function processPerformanceData(performanceData)
    if not performanceData then return end
    if performanceData.powertrainLayout then labelDrivetrain(performanceData) end
    if performanceData.fuelType then
      performanceData.fuelType = labelFromFlags(performanceData.fuelType, FUEL_TYPE_LABELS)
    end
    if performanceData.inductionType then
      performanceData.inductionType = labelFromFlags(performanceData.inductionType, INDUCTION_TYPE_LABELS)
    end
    if performanceData.lateralAcceleration then
      performanceData.lateralGForce = performanceData.lateralAcceleration.maxAcceleration / 9.81
    end
    overhaul_career_parts_vehiclePerformance.addScoresToPerformanceData(performanceData)
    if type(performanceData.power) == "table" and performanceData.power.propulsionPowerCombined and performanceData.weight then
      local powerInHP = performanceData.power.propulsionPowerCombined / 735.5
      performanceData.powerPerTon = powerInHP * 1000 / performanceData.weight
      performanceData.power = powerInHP
    end
    overhaul_career_parts_vehiclePerformance.translatePerformanceDataForUi(performanceData)
  end

  local function getConfigFallbackNiceName(vehicleData)
    if not vehicleData or not vehicleData.model or not vehicleData.config then return end
    local partConfigFilename = vehicleData.config.partConfigFilename
    if type(partConfigFilename) ~= "string" or partConfigFilename == "" then return end
    local _, configFilename = path.splitWithoutExt(partConfigFilename)
    local configInfo = core_vehicles.getConfig(vehicleData.model, configFilename)
    if not configInfo then return end
    local configName = configInfo.Name
    configName = core_locales.translateWithOrWithoutContext(configName)
    if type(configName) ~= "string" or configName == "" then return end
    local brand = configInfo.Brand
    brand = core_locales.translateWithOrWithoutContext(brand)
    if type(brand) == "string" and brand ~= "" then
      return brand .. " " .. configName
    end
    return configName
  end

  local function getVehicleNiceNameTranslated(inventoryId)
    local vehicleData = vehicles[inventoryId]
    if not vehicleData then return end
    local niceName = vehicleData.niceName
    niceName = core_locales.translateWithOrWithoutContext(niceName)
    -- Dual-brand locale tables (e.g. md_series) must never reach Vue as objects.
    if type(niceName) == "string" and niceName ~= "" then
      return niceName
    end
    local fallback = getConfigFallbackNiceName(vehicleData)
    if type(fallback) == "string" and fallback ~= "" then
      return fallback
    end
    if type(vehicleData.model) == "string" and vehicleData.model ~= "" then
      return vehicleData.model
    end
    return "Vehicle"
  end

  -- Keep a saved class snapshot so stored vehicles have stable inventory tiles.
  local function syncSavedVehicleClassUiSnapshot(inventoryId, certificationDataProcessed)
    if type(inventoryId) ~= "number" or type(certificationDataProcessed) ~= "table" then
      return
    end
    local vehicleClass = certificationDataProcessed.vehicleClass
    if type(vehicleClass) ~= "table" then
      return
    end
    local performanceIndex = tonumber(vehicleClass.performanceIndex)
    if not performanceIndex then
      return
    end
    local snapshot = {
      performanceIndex = performanceIndex,
      label = type(vehicleClass.label) == "string" and vehicleClass.label or type(vehicleClass.name) == "string" and vehicleClass.name or nil,
    }
    local veh = vehicles[inventoryId]
    if not veh then
      return
    end
    local previous = veh.savedVehicleClassUi
    local previousIndex = previous and tonumber(previous.performanceIndex)
    local previousLabel = previous and previous.label or ""
    local newLabel = snapshot.label or ""
    if not previous or previousIndex ~= snapshot.performanceIndex or previousLabel ~= newLabel then
      veh.savedVehicleClassUi = snapshot
      helpers.setVehicleDirty(inventoryId)
    end
  end

  -- Insured cars use the coverage repair time; uninsured cars use the private repair time they were delayed with.
  local function getInitialRepairTime(inventoryId)
    local repairTime = tonumber((overhaul_career_repair_insurance.getInvVehRepairTime(inventoryId)))
    if repairTime and repairTime > 0 then return repairTime end
    local vehInfo = vehicles[inventoryId]
    if not vehInfo then return end
    return tonumber(vehInfo.repairTimeTotal) or vehInfo.timeToAccess
  end

  local function applyValueFields(vehicleData, inventoryId)
    vehicleData.niceName = getVehicleNiceNameTranslated(inventoryId)
    vehicleData.value = overhaul_career_market_valueCalculator.getInventoryVehicleValue(inventoryId)
    vehicleData.marketSellValue = overhaul_career_market_valueCalculator.getInventoryVehicleSellValue(inventoryId)
    vehicleData.valueRepaired = overhaul_career_market_valueCalculator.getInventoryVehicleValue(inventoryId, true)
    vehicleData.quickRepairExtraPrice = overhaul_career_repair_insurance.getQuickRepairExtraPrice()
    vehicleData.initialRepairTime = getInitialRepairTime(inventoryId)
  end

  local function applyCertificationText(vehicleData)
    if vehicleData.certifications then
      vehicleData.power = string.format("%d", vehicleData.certifications.power)
      vehicleData.weight = string.format("%d", vehicleData.certifications.weight)
      vehicleData.torque = string.format("%d", vehicleData.certifications.torque)
      vehicleData.powerPerWeight = string.format("%0.3f", vehicleData.certifications.power / vehicleData.certifications.weight)
    else
      vehicleData.power = "N/A"
      vehicleData.weight = "N/A"
      vehicleData.torque = "N/A"
      vehicleData.powerPerWeight = "N/A"
    end
  end

  local function applyLocationFields(vehicleData, inventoryId, currentGarageId, inventoryIdsInGarage)
    vehicleData.mileage = M.setMileage(inventoryId)
    vehicleData.niceLocation = vehicleData.niceLocation or (vehicleData.location and overhaul_career_garage_garageManager.garageIdToName(vehicleData.location)) or "Storage"
    if inventoryIdToVehId[inventoryId] then
      local vehObj = getObjectByID(inventoryIdToVehId[inventoryId])
      if vehObj then
        vehicleData.distance = vehObj:getPosition():distance(getPlayerVehicle(0):getPosition())
        vehicleData.inGarage = inventoryIdsInGarage[inventoryId]
      end
      vehicleData.inStorage = false
    else
      vehicleData.inStorage = true
    end
    vehicleData.atCurrentGarage = (currentGarageId and vehicleData.location == currentGarageId) or vehicleData.inGarage
    for otherInventoryId, _ in pairs(inventoryIdsInGarage) do
      if otherInventoryId ~= inventoryId then
        vehicleData.otherVehicleInGarage = true
        break
      end
    end
  end

  local function applyStatusFlags(vehicleData, inventoryId, garage)
    vehicleData.needsRepair = overhaul_career_repair_insurance.inventoryVehNeedsRepair(vehicleData.id)
    vehicleData.onSite = garage and isVehicleOnSite(inventoryId, garage) or false
    if inventoryId == garageState.favoriteVehicle then
      vehicleData.favorite = true
    end
  end

  local function applyInsuranceFields(vehicleData, inventoryId)
    local vehInsuranceInfo = overhaul_career_repair_insurance.getVehInsuranceInfo(inventoryId)
    if vehInsuranceInfo then
      vehicleData.insuranceInfo = vehInsuranceInfo.insuranceInfo
      vehicleData.isInsured = vehInsuranceInfo.isInsured
      vehicleData.insuranceClass = vehInsuranceInfo.insuranceClass
      vehicleData.thumbnail = getVehicleThumbnail(inventoryId)
    end
  end

  local function permissionStatus(tags, inventoryId)
    return overhaul_career_permissions.getStatusForTag(tags, {inventoryId = inventoryId})
  end

  local function applyGaragePermissions(vehicleData, inventoryId, currentGarageId)
    vehicleData.junkVehicle = permissionStatus("junkVehicle", inventoryId)
    vehicleData.repairPermission = permissionStatus("vehicleRepair", inventoryId)
    vehicleData.sellPermission = permissionStatus("vehicleSelling", inventoryId)
    vehicleData.favoritePermission = permissionStatus("vehicleFavorite", inventoryId)
    vehicleData.storePermission = permissionStatus("vehicleStoring", inventoryId)
    local garageHasSpace = currentGarageId and overhaul_career_garage_garageManager.isGarageSpace(currentGarageId)[1] or false
    local storeGarageHasSpace = currentGarageId and overhaul_career_garage_garageManager.isGarageSpace(currentGarageId, inventoryId)[1] or false
    local globalGarageHasSpace = helpers.hasFreeSlot()
    if vehicleData.storePermission.allow then
      if not currentGarageId then
        vehicleData.storePermission.allow = false
        vehicleData.storePermission.label = "No current garage."
      elseif vehicleData.location ~= currentGarageId and not vehicleData.inGarage then
        vehicleData.storePermission.allow = false
        vehicleData.storePermission.label = "Vehicle must be in the current garage to store it."
      elseif not storeGarageHasSpace then
        vehicleData.storePermission.allow = false
        vehicleData.storePermission.label = "This garage is full."
      end
    end
    local freightPickupPending =
      string.find(tostring(vehicleData.location or ""), "freightPickup:", 1, true) == 1
    vehicleData.deliverPermission = {
      allow = not freightPickupPending and
        ((garageHasSpace or globalGarageHasSpace) and
          vehicleData.location ~= currentGarageId and not vehicleData.inGarage)
    }
  end

  local function applyRetrievalFields(vehicleData, inventoryId, currentGarageId, localRetrievalRoutePrice)
    local storedAtCurrentGarage = isVehicleStoredAtGarage(inventoryId, currentGarageId)
    vehicleData.retrievePermission = {allow = storedAtCurrentGarage}
    local retrievalQuote = storedAtCurrentGarage
      and {cost = 0, coveredByInsurance = false}
      or inputs.getVehicleRetrievalQuote(inventoryId, localRetrievalRoutePrice)
    vehicleData.retrievalCost = retrievalQuote.cost
    vehicleData.retrievalCoveredByInsurance = retrievalQuote.coveredByInsurance
    vehicleData.retrievalFree = storedAtCurrentGarage
    local storageTowQuote = (inventoryIdToVehId[inventoryId] and not vehicleData.inGarage)
      and inputs.getVehicleRetrievalQuote(inventoryId, localRetrievalRoutePrice)
      or {cost = 0, coveredByInsurance = false}
    vehicleData.storageTowCost = storageTowQuote.cost
    vehicleData.storageTowCoveredByInsurance = storageTowQuote.coveredByInsurance
    vehicleData.storageTowRequired = storageTowQuote.cost > 0 or storageTowQuote.coveredByInsurance
  end

  local function applyListingAndPerformance(vehicleData, inventoryId)
    local marketplaceListed = overhaul_career_market_marketplace.findVehicleListing(inventoryId) ~= nil
    vehicleData.listedForSale = marketplaceListed
    vehicleData.listedForAuction = vehicleData.listedForAuction == true
    for _, performanceData in ipairs(vehicleData.performanceHistory or {}) do
      processPerformanceData(performanceData)
    end
    if vehicleData.certificationData then
      processPerformanceData(vehicleData.certificationData)
      syncSavedVehicleClassUiSnapshot(inventoryId, vehicleData.certificationData)
    end
    local vehStore = vehicles[inventoryId]
    if vehStore and type(vehStore.savedVehicleClassUi) == "table" then
      vehicleData.savedVehicleClassUi = deepcopy(vehStore.savedVehicleClassUi)
    end
  end

  local function buildVehicleUiData(inventoryId, inventoryIdsInGarage, localRetrievalRoutePrice, includeDetails)
    local vehicle = vehicles[inventoryId]
    if not vehicle then return end
    local vehicleData = includeDetails and deepcopy(vehicle) or {}
    if not includeDetails then
      for _, field in ipairs(VEHICLE_LIST_FIELDS) do
        vehicleData[field] = deepcopy(vehicle[field])
      end
    end
    local conditionSum, conditionCount = 0, 0
    for _, condition in pairs(vehicle.partConditions or {}) do
      conditionSum = conditionSum + (tonumber(condition.integrityValue) or 0)
      conditionCount = conditionCount + 1
    end
    vehicleData.conditionAvg = conditionCount > 0 and conditionSum / conditionCount or 1
    vehicleData.licenseName = vehicle.config and vehicle.config.licenseName
    local garage = getInventoryMenuGarage()
    local currentGarageId = garage and garage.id
    if currentGarageId then overhaul_career_garage_garageManager.isGarageSpace(currentGarageId) end
    if not inventoryIdsInGarage then
      inventoryIdsInGarage = garage and getVehiclesInGarage(garage, true) or {}
    end
    applyValueFields(vehicleData, inventoryId)
    applyCertificationText(vehicleData)
    applyLocationFields(vehicleData, inventoryId, currentGarageId, inventoryIdsInGarage)
    applyStatusFlags(vehicleData, inventoryId, garage)
    applyInsuranceFields(vehicleData, inventoryId)
    applyGaragePermissions(vehicleData, inventoryId, currentGarageId)
    applyRetrievalFields(vehicleData, inventoryId, currentGarageId, localRetrievalRoutePrice)
    vehicleData.licensePlateChangePermission = permissionStatus({"vehicleLicensePlate", "vehicleModification"}, inventoryId)
    vehicleData.returnLoanerPermission = permissionStatus("returnLoanedVehicle", inventoryId)
    applyListingAndPerformance(vehicleData, inventoryId)
    if not includeDetails then
      local certification = vehicleData.certificationData
      local class = certification and certification.vehicleClass
      vehicleData.certificationData = certification and {
        power = certification.power, weight = certification.weight,
        vehicleClass = class and {label = class.label, name = class.name, performanceIndex = class.performanceIndex},
      }
      vehicleData.certifications = nil
      vehicleData.power, vehicleData.weight, vehicleData.torque = nil, nil, nil
      vehicleData.onSite, vehicleData.insuranceClass, vehicleData.junkVehicle = nil, nil, nil
      vehicleData.retrievePermission = nil
      local insuranceInfo = vehicleData.insuranceInfo
      vehicleData.insuranceInfo = insuranceInfo and {name = insuranceInfo.name}
    end
    return vehicleData
  end

  local function getVehicleUiData(inventoryId, inventoryIdsInGarage, localRetrievalRoutePrice)
    return buildVehicleUiData(inventoryId, inventoryIdsInGarage, localRetrievalRoutePrice, false)
  end

  -- Detail screens opt in to conditions, configuration and assessment history for one car.
  local function getVehicleDetailsUiData(inventoryId)
    return buildVehicleUiData(inventoryId, nil, nil, true)
  end

  -- Menu projection -------------------------------------------------------------------------------

  local function buildInventoryUiData()
    menuIsOpen = true
    local data = {vehicles = {}}
    data.menuHeader = menuHeader
    data.chooseButtonsData = chooseButtonsData
    data.buttonsActive = buttonsActive
    local closestGarage = getInventoryMenuGarage()
    local closestGarageId = closestGarage and closestGarage.id
    local inventoryIdsInGarage = getVehiclesInGarage(closestGarage, true)
    local localRetrievalRoutePrice = inputs.getLocalGarageRetrievalRoutePrice()
    for inventoryId in pairs(vehicles) do
      if helpers.isPersonalInventoryId(inventoryId) then
        data.vehicles[tostring(inventoryId)] =
          getVehicleUiData(inventoryId, inventoryIdsInGarage, localRetrievalRoutePrice)
      end
    end
    data.numberOfFreeSlots = helpers.getNumberOfFreeSlots()
    data.hasGlobalGarageSpace = helpers.hasFreeSlot()
    data.originComputerId = garageState.originComputerId
    data.currentGarageId = closestGarageId
    if closestGarageId then
      local spaceInfo = overhaul_career_garage_garageManager.isGarageSpace(closestGarageId)
      data.currentGarageHasSpace = spaceInfo[1]
      data.currentGarageFreeSlots = spaceInfo[2]
    end
    data.playerMoney = overhaul_career_economy_playerAttributes.getAttributeValue("money")
    return data
  end

  local function sendDataToUi()
    local data = buildInventoryUiData()
    publishedVehicles = data.vehicles
    guihooks.trigger("vehicleInventoryData", data)
  end

  local function valuesEqual(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return left == right end
    for key, value in pairs(left) do
      if not valuesEqual(value, right[key]) then return false end
    end
    for key in pairs(right) do
      if left[key] == nil then return false end
    end
    return true
  end

  local function sendVehicleUpdatesToUi()
    if not publishedVehicles then return sendDataToUi() end
    local data = buildInventoryUiData()
    local nextVehicles, changedVehicles, removedVehicleIds = data.vehicles, {}, {}
    -- Storage and sales can change permissions on other cars, so compare the whole slim projection.
    for id, vehicle in pairs(nextVehicles) do
      if not valuesEqual(vehicle, publishedVehicles[id]) then changedVehicles[id] = vehicle end
    end
    for id in pairs(publishedVehicles) do
      if not nextVehicles[id] then table.insert(removedVehicleIds, id) end
    end
    publishedVehicles = nextVehicles
    data.vehicles, data.removedVehicleIds, data.isUpdate = changedVehicles, removedVehicleIds, true
    guihooks.trigger("vehicleInventoryData", data)
  end

  local function openMenu(_chooseButtonsData, header, _buttonsActive, _backTarget)
    publishedVehicles = nil
    menuBackTarget = _backTarget
    buttonsActive = _buttonsActive or {}
    for _, key in ipairs(BUTTONS_ENABLED_BY_DEFAULT) do
      if buttonsActive[key] == nil then buttonsActive[key] = true end
    end
    menuHeader = header or _tr("ui.career.computer.functions.vehicleInventory")

    chooseButtonsData = _chooseButtonsData or {{}}
    for _, buttonData in ipairs(chooseButtonsData) do
      buttonData.buttonText = buttonData.buttonText or _tr("ui.career.inventory.button.chooseVehicle")
      if buttonData.repairRequired == nil then buttonData.repairRequired = false end
      if buttonData.insuranceRequired == nil then buttonData.insuranceRequired = false end
      if buttonData.ownedRequired == nil then buttonData.ownedRequired = false end
      buttonData.callback = buttonData.callback or function() end
    end

    -- Always open the inventory picker route; 4th arg is where Back returns (0.39).
    extensions.ui_router.navigate("overhaul.computer.vehicleInventory")
    helpers.updatePartConditionsOfSpawnedVehicles()
  end

  local function closeMenu()
    if closeMenuCallback then
      closeMenuCallback()
    else
      overhaul_career_career.closeAllMenus()
    end
  end

  local function requestPickerExit()
    return extensions.ui_router.navigate(menuBackTarget or "overhaul.computer")
  end

  -- Fade callbacks --------------------------------------------------------------------------------

  local function onScreenFadeState(state)
    if callbackAfterFade and state == 1 then
      overhaul_career_garage_vehicleDeletionService.deleteFlaggedVehicles()
      callbackAfterFade()
      callbackAfterFade = nil
    end
  end

  -- Retrieval and API -----------------------------------------------------------------------------

  local function spawnVehicleAfterFade(enterAfterSpawn, inventoryId, callback)
    ui_fadeScreen.start(0.5)
    callbackAfterFade = function()
      if enterAfterSpawn then
        helpers.enterVehicle(inventoryId, nil, callback)
      else
        if inventoryIdToVehId[inventoryId] then
          callback()
        elseif not helpers.spawnVehicle(inventoryId, nil, callback, nil, true) then
          ui_fadeScreen.stop(0.5)
          local vehInfo = vehicles[inventoryId]
          if not (vehInfo and vehInfo.listedForAuction) then
            guihooks.trigger("toastrMsg", {type="error", label = "vehSpawnFailed", title = _tr("ui.career.inventory.toast.vehicleSpawnFailed.title"), msg = _tr("ui.career.inventory.toast.vehicleSpawnFailed.msg")})
          end
        end
      end
    end
  end

  local function spawnVehicleAndTeleportToGarage(enterAfterSpawn, inventoryId, replaceOthers, onDelivered)
    if inventoryId == garageState.currentVehicle then return end
    spawnVehicleAfterFade(enterAfterSpawn, inventoryId,
    function(success, reason)
      if success == false then
        ui_fadeScreen.stop(0.5)
        ui_message(reason or 'Vehicle retrieval failed.', 5, 'Vehicle retrieval', 'error')
        return
      end
      if replaceOthers then
        removeVehiclesFromGarageExcept(inventoryId)
      end
      local vehObj = getObjectByID(inventoryIdToVehId[inventoryId])
      if not vehObj then
        ui_fadeScreen.stop(0.5)
        return
      end
      setPartConditionResetSnapshot(vehObj,
        function()
          local closestGarage = getInventoryMenuGarage()
          if not closestGarage or not closestGarage.id then
            if M.completeVehiclePlacement then M.completeVehiclePlacement(inventoryId, vehObj:getID()) end
            log("E", "inventory", string.format("Unable to retrieve inventory vehicle %s: no destination garage", tostring(inventoryId)))
            ui_message("Could not find the current garage.", 5, "Vehicle retrieval", "error")
            ui_fadeScreen.stop(0.5)
            return
          end
          overhaul_world_facilities.teleportToGarage(closestGarage.id, vehObj, false)
          if M.completeVehiclePlacement then M.completeVehiclePlacement(inventoryId, vehObj:getID()) end
          if onDelivered then onDelivered() end
          overhaul_career_maintenance_fuel.minimumRefuelingCheck(vehObj:getId())
          helpers.setVehicleDirty(inventoryId)
          extensions.ui_router.navigate('play')
          ui_fadeScreen.stop(0.5)

          local pos, _ = overhaul_world_facilities.getGaragePosRot(closestGarage, vehObj)
          overhaul_career_police_playerDriving.showPosition(pos)

          overhaul_career_ui_log.addLog(string.format("Spawned vehicle %d in garage %s. replaceOthers == %s", inventoryId, closestGarage.id, replaceOthers), "inventory")
        end)
    end)
  end

  local function retrieveVehicleFromStorage(inventoryId, replaceOthers)
    local currentGarage = getInventoryMenuGarage()
    if inventoryId == garageState.currentVehicle then return end
    if not currentGarage or not currentGarage.id then
      ui_message("Could not find the current garage.", 5, "Vehicle retrieval", "error")
      return
    end
    local storedAtCurrentGarage =
      currentGarage and isVehicleStoredAtGarage(inventoryId, currentGarage.id)
    local routePrice = inputs.getLocalGarageRetrievalRoutePrice()
    spawnVehicleAndTeleportToGarage(false, inventoryId, replaceOthers, function()
      if not storedAtCurrentGarage then
        inputs.useVehicleRetrievalService(inventoryId, routePrice, "Retrieved vehicle with towing service")
      end
    end)
  end

  local function deliverAndReplace(inventoryId)
    M.deliverVehicle(inventoryId, 5000)
    local closestGarage = getInventoryMenuGarage()
    if closestGarage then
      M.moveVehicleToGarage(inventoryId, closestGarage.id)
    end
    sendVehicleUpdatesToUi()
  end

  local function openMenuFromComputer(_originComputerId)
    garageState.originComputerId = _originComputerId
    openMenu(
      {
        {
          callback = function(inventoryId) retrieveVehicleFromStorage(inventoryId, false) end,
          buttonText = _tr("ui.career.inventory.button.retrieve"),
          retrievalAction = true,
          insuranceRequired = true,
          requiredVehicleNotInGarage = true,
          requireAtCurrentGarage = true
        },
        {
          callback = function(inventoryId) retrieveVehicleFromStorage(inventoryId, true) end,
          buttonText = _tr("ui.career.inventory.button.replaceCurrentVehicle"),
          retrievalAction = true,
          insuranceRequired = true,
          requiredOtherVehicleInGarage = true,
          requireAtCurrentGarage = true
        },
        {
          callback = function(inventoryId) M.deliverVehicle(inventoryId, 5000) end,
          buttonText = "Deliver",
          insuranceRequired = true,
          requiredVehicleNotInGarage = true,
          requireAtDifferentGarage = true
        },
        {
          callback = function(inventoryId) deliverAndReplace(inventoryId) end,
          buttonText = "Deliver and replace",
          insuranceRequired = true,
          requiredVehicleNotInGarage = true,
          requiredOtherVehicleInGarage = true,
          requireAtDifferentGarage = true
        },
        {
          callback = function(inventoryId)
            overhaul_career_parts_vehiclePerformance.openMenu({inventoryId = inventoryId, computerId = garageState.originComputerId})
          end,
          buttonText = _tr("ui.career.shared.pathPerformanceIndex"),
          repairRequired = false
        }
      },
      _tr("ui.career.inventory.menu.spawnVehicle"), nil
    )
    overhaul_career_ui_log.addLog(string.format("Opened vehicle inventory from computer %s", garageState.originComputerId), "inventory")
  end

  local function chooseVehicleFromMenu(inventoryId, buttonIndex, repairPrevVeh)
    chooseButtonsData[buttonIndex].callback(inventoryId, repairPrevVeh)
  end

  local function openInventoryMenuForChoosingListing()
    openMenu(
      {{
        callback = function(inventoryId)
          guihooks.trigger('addListing', {inventoryId = inventoryId})
        end,
        buttonText = _tr("ui.career.inventory.button.listForSale"),
        repairRequired = false,
        ownedRequired = true,
        notForSaleRequired = true,
      }}, _tr("ui.career.inventory.menu.listForSale"),
      {
        repairEnabled = false,
        sellEnabled = false,
        favoriteEnabled = false,
        storingEnabled = false,
        returnLoanerEnabled = false
      },
      "overhaul.computer.vehicleShopping"
    )
  end

  local function onExitVehicleInventory()
    publishedVehicles = nil
    menuIsOpen = false
    menuHeader = nil
    menuBackTarget = nil
  end

  local function onOverhaulEnterVehicleFinished(inventoryId)
    if inventoryId then
      garageState.lastVehicle = inventoryId
    end
  end

  local function onBeforeWalkingModeToggled(enabled, vehicleInFrontVehId)
    if enabled then
      helpers.enterVehicle(nil, garageState.skipPartConditionsBeforeWalking and 1 or nil)
    elseif inputs.vehIdToInventoryId[vehicleInFrontVehId] then
      helpers.enterVehicle(inputs.vehIdToInventoryId[vehicleInFrontVehId], 1)
    end
    garageState.skipPartConditionsBeforeWalking = nil
  end

  return {
    chooseVehicleFromMenu = chooseVehicleFromMenu,
    closeMenu = closeMenu,
    getCurrentVehicleId = getCurrentVehicleId,
    getInitialRepairTime = getInitialRepairTime,
    getInventoryIdFromVehicleId = getInventoryIdFromVehicleId,
    getInventoryIdsInClosestGarage = getInventoryIdsInClosestGarage,
    getLastVehicle = getLastVehicle,
    getMapInventoryIdToVehId = getMapInventoryIdToVehId,
    getVehicleIdFromInventoryId = getVehicleIdFromInventoryId,
    getVehicleNiceNameTranslated = getVehicleNiceNameTranslated,
    getVehicleThumbnail = getVehicleThumbnail,
    getVehicleUiData = getVehicleUiData,
    getVehicleDetailsUiData = getVehicleDetailsUiData,
    getVehiclesInGarage = getVehiclesInGarage,
    isMenuOpen = function() return menuIsOpen end,
    isSeatedInsideOwnedVehicle = isSeatedInsideOwnedVehicle,
    onBeforeWalkingModeToggled = onBeforeWalkingModeToggled,
    onBigMapActivated = onBigMapActivated,
    onExitVehicleInventory = onExitVehicleInventory,
    onOverhaulEnterVehicleFinished = onOverhaulEnterVehicleFinished,
    onScreenFadeState = onScreenFadeState,
    openInventoryMenuForChoosingListing = openInventoryMenuForChoosingListing,
    openMenu = openMenu,
    openMenuFromComputer = openMenuFromComputer,
    requestPickerExit = requestPickerExit,
    sendDataToUi = sendDataToUi,
    sendVehicleUpdatesToUi = sendVehicleUpdatesToUi,
    teleportedFromBigmap = teleportedFromBigmap,
    bindInputs = function(inputs)
      helpers.enterVehicle = inputs.enterVehicle
      helpers.getNumberOfFreeSlots = inputs.getNumberOfFreeSlots
      helpers.hasFreeSlot = inputs.hasFreeSlot
      helpers.isPersonalInventoryId = inputs.isPersonalInventoryId
      helpers.setVehicleDirty = inputs.setVehicleDirty
      helpers.spawnVehicle = inputs.spawnVehicle
      helpers.updatePartConditionsOfSpawnedVehicles = inputs.updatePartConditionsOfSpawnedVehicles
    end,
  }
end

return ui
