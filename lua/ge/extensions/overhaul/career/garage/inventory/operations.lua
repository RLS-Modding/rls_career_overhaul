-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Inventory operations own sales, repairs, licence plates, permissions, records and garage moves.
-- Read in order: queries, sales, access, recovery, licence plates, permissions, POIs, race records and storage.
local operations = {}
require("overhaul/lib/progression/logbookRegistry").registerType("overhaul.vehicleSold", function(data)
  if type(data.name) ~= "string" or type(data.price) ~= "number" then return end
  return {icon = "carCoins", title = "Vehicle sold: " .. data.name, label = "Vehicle sale", money = data.price,
    text = string.format("Sold %s for $%.2f.", data.name, data.price)}
end, "overhaul.inventory")

function operations.new(inputs)
  local garageState = inputs.state
  local M = inputs.M
  local dirtiedVehicles = inputs.dirtiedVehicles
  local inventoryIdToVehId = inputs.inventoryIdToVehId
  local vehicles = inputs.vehicles
  local helpers = {}

  -- Queries ---------------------------------------------------------------------------------------

  local function getVehicles()
    return vehicles
  end

  local function getVehicle(inventoryId)
    return vehicles[inventoryId]
  end

  local function getVehicleTimeToAccess(inventoryId)
    return vehicles[inventoryId].timeToAccess
  end

  local function getDirtiedVehicles()
    return dirtiedVehicles
  end

  local function isEmpty()
    return tableIsEmpty(vehicles)
  end

  local function isLicensePlateValid(text)
    return core_vehicles.isLicensePlateValid(text)
  end

  local function isVehicleNameValid(text)
    if not text or text == "" then return false end
    return not text:find('["\\\b\f\n\r\t]')
  end

  -- Sales and repairs -----------------------------------------------------------------------------

  local function saveAndRefreshUi()
    overhaul_career_saveSystem.saveCurrent()
    helpers.sendDataToUi()
  end

  local function sellVehicle(inventoryId, price)
    local delivery = overhaul_career_logistics_general
    if not delivery.canRemoveLogisticsVehicle(inventoryId) then return false end
    local vehicle = vehicles[inventoryId]
    if not vehicle then return end
    if vehicle.timeToAccess then
      local reasonText = vehicle.delayReason == "rented" and "the vehicle is currently rented to the movie studio" or "the vehicle is not currently accessible"
      log("W", "inventory", string.format("Cannot sell vehicle %d because %s", inventoryId, reasonText))
      return false
    end
    if vehicle.listedForAuction then return false end

    local salePrice = price or overhaul_career_market_valueCalculator.getInventoryVehicleSellValue(inventoryId)
    extensions.hook("onOverhaulBeforeVehicleSell", {inventoryId = inventoryId, price = salePrice})
    overhaul_career_economy_playerAttributes.addAttributes({money=salePrice}, {
      category = "sale", finance = {vehicleId = inventoryId, vehicleName = vehicle.niceName},
      tags={"vehicleSold","selling"}, label = {txt = "ui.career.inventory.log.soldVehicle", context = {vehicleName = vehicle.niceName or "ui.career.inventory.unnamedVehicle"}}}, true)
    helpers.removeVehicle(inventoryId)
    local ok, reason = pcall(extensions.hook, "onOverhaulLogbookEvent", "overhaul.vehicleSold", {
      name = vehicle.niceName or "Unnamed vehicle", price = salePrice,
    })
    if not ok and log then log("W", "inventory", tostring(reason)) end
    Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
    if vehicle.finalBuyingPrice and salePrice > vehicle.finalBuyingPrice then
      gameplay_achievement.unlockAchievement("FLIP_PROFIT")
    end
    overhaul_career_ui_log.addLog(string.format("Sold vehicle %d for %f", inventoryId, salePrice), "inventory")
    overhaul_career_saveSystem.saveCurrent()
    return true
  end

  local function sellVehicleFromInventory(inventoryId)
    if sellVehicle(inventoryId) then saveAndRefreshUi() end
  end

  local function returnLoanedVehicleFromInventory(inventoryId)
    overhaul_career_logistics_loanerVehicles.returnVehicle(inventoryId, saveAndRefreshUi)
  end

  -- The UI price is display only; the charge is computed here from the remaining repair time.
  local function expediteRepairFromInventory(inventoryId)
    local vehicle = vehicles[inventoryId]
    if not vehicle or not vehicle.timeToAccess or vehicle.delayReason ~= "repair" or helpers.isVehicleListedForAuction(inventoryId) then
      return
    end
    local insurance = overhaul_career_repair_insurance
    local price = insurance.getQuickRepairExtraPrice()
    local initialRepairTimeSeconds = tonumber(helpers.getInitialRepairTime(inventoryId)) or 0
    if initialRepairTimeSeconds > 0 then
      price = math.max(price * (vehicle.timeToAccess / initialRepairTimeSeconds), 50)
    end
    insurance.expediteRepair(inventoryId, price)
    overhaul_career_saveSystem.saveCurrent()
    helpers.sendDataToUi()
  end

  local function delayVehicleAccess(inventoryId, delay, reason)
    local vehicle = vehicles[inventoryId]
    if not vehicle or delay <= 0 then return end
    vehicle.timeToAccess = delay
    vehicle.delayReason = reason
    vehicle.repairTimeTotal = reason == "repair" and delay or nil
  end

  local function onAvailableMissionsSentToUi()
    if not garageState.currentVehicle then return end
    helpers.updatePartConditions(inventoryIdToVehId[garageState.currentVehicle], garageState.currentVehicle, function()
      guihooks.trigger('gameContextPlayerVehicleDamageInfo', {needsRepair = overhaul_career_repair_insurance.inventoryVehNeedsRepair(garageState.currentVehicle)})
    end)
  end

  -- Favourite and recovery ------------------------------------------------------------------------

  local function setFavoriteVehicle(inventoryId)
    if vehicles[inventoryId] and not vehicles[inventoryId].listedForAuction then
      garageState.favoriteVehicle = inventoryId
    end
  end

  local function getFavoriteVehicle()
    return garageState.favoriteVehicle
  end

  local function isRecoverablePersonalVehicle(inventoryId)
    local vehicle = inventoryId and vehicles[inventoryId]
    if not vehicle then return false end
    if vehicle.loanType then return false end
    if vehicle.timeToAccess or vehicle.listedForAuction then return false end
    return true
  end

  local function findRecoveryInventoryId()
    if isRecoverablePersonalVehicle(garageState.lastVehicle) then return garageState.lastVehicle end
    if isRecoverablePersonalVehicle(garageState.favoriteVehicle) then return garageState.favoriteVehicle end
    for inventoryId in pairs(vehicles) do
      if isRecoverablePersonalVehicle(inventoryId) then return inventoryId end
    end
    return nil
  end

  local function recoverPlayerAfterCompanyReturn()
    spawn.preventPlayerSpawning = nil
    local recoveryInventoryId = findRecoveryInventoryId()
    if recoveryInventoryId then
      local didEnterVehicle = pcall(function()
        helpers.enterVehicle(recoveryInventoryId)
      end)
      if didEnterVehicle and (inventoryIdToVehId[recoveryInventoryId] or garageState.currentVehicle == recoveryInventoryId) then
        helpers.ensureGameCameraWithRetry()
        return "vehicle"
      end
    end

    local levelName = getCurrentLevelIdentifier()
    if not helpers.teleportWalkFallback(levelName, nil, nil) then
      gameplay_walk.setWalkingMode(true, nil, nil, true)
    end
    inputs.teleportPlayerToStartingGarage(levelName)
    helpers.ensureGameCameraWithRetry()
    return "garage"
  end

  local function onOverhaulComputerAddFunctions(menuData, computerFunctions)
    if not menuData.computerFacility.functions["vehicleInventory"] then return end
    local computerFunctionData = {
      id = "vehicleInventory",
      routeTarget = "overhaul.computer.vehicleInventory",
      label = _tr("ui.career.shared.myVehicles"),
      callback = function() helpers.openMenuFromComputer(menuData.computerFacility.id) end,
      order = 1
    }
    if not menuData.hasBoughtStarterVehicle then
      computerFunctionData.disabled = true
      computerFunctionData.reason = overhaul_career_garage_computer.reasons.hasBoughtStarterVehicle
    end
    computerFunctions.general[computerFunctionData.id] = computerFunctionData
  end

  -- Licence plates --------------------------------------------------------------------------------

  local function setLicensePlateText(inventoryId, text)
    if helpers.isVehicleListedForAuction(inventoryId) then return end
    local vehId = helpers.getVehicleIdFromInventoryId(inventoryId)
    if inventoryId then
      core_vehicles.setPlateText(text, vehId)
    end
    vehicles[inventoryId].config.licenseName = text
  end

  local function getLicensePlateText(vehId)
    local inventoryId = helpers.getInventoryIdFromVehicleId(vehId)
    return inventoryId and vehicles[inventoryId] and vehicles[inventoryId].config.licenseName or nil
  end

  local function getLicensePlateCost()
    return 300
  end

  local function purchaseLicensePlateText(inventoryId, text)
    local vehicle = vehicles[inventoryId]
    if not vehicle or not vehicle.owned or not vehicle.config or helpers.isVehicleListedForAuction(inventoryId)
      or type(text) ~= "string" or #text == 0 or #text > 10 or not text:find("%S")
      or not core_vehicles.isLicensePlateValid(text) then
      return false
    end
    if vehicle.config.licenseName == text then return true end
    local price = {money = {amount = getLicensePlateCost(), canBeNegative = false}}
    if not overhaul_career_economy_payment.pay(price, require("overhaul/lib/finance/metadata").tag({label = _tr("ui.career.inventory.payment.changeLicensePlateText"), tags = {"licensePlate", "buying"}}, "purchase", {vehicleId = inventoryId})) then return false end
    setLicensePlateText(inventoryId, text)
    gameplay_achievement.unlockAchievement("NOW_ITS_MINE")
    Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
    helpers.setVehicleDirty(inventoryId)
    overhaul_career_saveSystem.saveCurrent()
    return true
  end

  -- Permissions -----------------------------------------------------------------------------------

  local permissionTags = {
    notOwned = {
      vehicleSelling = "forbidden",
      vehicleRepair = "forbidden",
      interactMission = "forbidden",
      painting = "forbidden",
      partBuying = "forbidden",
      vehicleLicensePlate = "forbidden",
      tuning = "forbidden",
      vehicleStoring = "forbidden",
      partSwapping = "forbidden",
      recoveryTowToGarage = "forbidden",
      -- returnLoanedVehicle has no entry: only the unrestricted default reads as allow = true.
      vehicleFavorite = "forbidden",
      junkVehicle = "hidden"
    }
  }

  local AUCTION_LOCKED_TAGS = {
    vehicleSelling = true, vehicleFavorite = true, vehicleStoring = true, vehicleRepair = true,
    tuning = true, partSwapping = true, painting = true, vehicleModification = true,
    vehicleLicensePlate = true, junkVehicle = true, partBuying = true,
  }

  local function onOverhaulCheckPermission(tags, permissions, additionalData)
    if not additionalData or not additionalData.inventoryId then return end
    local vehicle = vehicles[additionalData.inventoryId]
    if not vehicle then return end

    for _, tag in ipairs(tags) do
      if not vehicle.owned then
        if permissionTags.notOwned[tag] then
          table.insert(permissions, {permission = permissionTags.notOwned[tag]})
        end
      elseif tag == "returnLoanedVehicle" then
        table.insert(permissions, {permission = "hidden"})
      end
      if tag == "junkVehicle" and not vehicle.missingFile then
        table.insert(permissions, {permission = "allowed"})
      end
      if tag == "vehicleRepair" and (vehicle.timeToAccess or vehicle.missingFile) then
        table.insert(permissions, {permission = "forbidden"})
      end
      if tag == "vehicleSelling" and vehicle.timeToAccess then
        table.insert(permissions, {permission = "forbidden"})
      end
      if vehicle.listedForAuction and AUCTION_LOCKED_TAGS[tag] then
        table.insert(permissions, {permission = "forbidden"})
      end
      if tag == "vehicleFavorite" and (vehicle.favorite or vehicle.missingFile) then
        table.insert(permissions, {permission = "forbidden"})
      end
      if tag == "vehicleStoring" and not inventoryIdToVehId[additionalData.inventoryId] then
        table.insert(permissions, {permission = "forbidden"})
      end
    end
  end

  -- Map points of interest ------------------------------------------------------------------------

  local function playerVehicleElement(inventoryId, vehId)
    local record = vehicles[inventoryId]
    local mapObject = map.objects[vehId]
    local description = _tr("ui.career.inventory.bigmap.playerVehicle")
    if record and record.loanType then
      description = _tr("ui.career.inventory.bigmap.loanedVehicle")
    end
    local id = "plVeh"..vehId
    local dist, distUnit = translateDistance(mapObject.pos:distance(getPlayerVehicle(0):getPosition()), true)
    local plate = (record and record.config and record.config.licenseName) or "Unknown"
    local odometer, odoUnit = translateDistance(overhaul_career_market_valueCalculator.getVehicleMileageById(inventoryId), true)
    description = core_locales.contextTranslate("ui.career.inventory.bigmap.description", {
      desc = description,
      dist = dist,
      distUnit = distUnit,
      plate = plate,
      odometer = odometer,
      odoUnit = odoUnit
    })
    return {
      id = id,
      data = {type = "playerVehicle", id = id},
      markerInfo = {
        bigmapMarker = {
          pos = mapObject.pos,
          icon = "vehicle_marker_outlined",
          name = core_locales.translateWithOrWithoutContext(record.niceName),
          description = description,
          thumbnail = helpers.getVehicleThumbnail(inventoryId),
          previews = {helpers.getVehicleThumbnail(inventoryId)},
          cluster = false
        }
      }
    }
  end

  local function onGetRawPoiListForLevel(_levelIdentifier, elements)
    if not overhaul_career_career.isActive() then return end
    for inventoryId, vehId in pairs(inventoryIdToVehId) do
      -- the player's current vehicle gets no marker
      if be:getPlayerVehicleID(0) ~= vehId and map.objects[vehId] then
        table.insert(elements, playerVehicleElement(inventoryId, vehId))
      end
    end
  end

  -- Rename and debug ------------------------------------------------------------------------------

  local function renameVehicle(inventoryId, name)
    if not isVehicleNameValid(name) then
      log("E", "inventory", "Invalid characters in vehicle name: " .. name)
      return false
    end
    if helpers.isVehicleListedForAuction(inventoryId) then return false end
    vehicles[inventoryId].niceName = name
    helpers.setVehicleDirty(inventoryId)
    return true
  end

  local function debugRespawnCurrentVehicle()
    local inventoryId = helpers.getCurrentVehicle()
    if not inventoryId then return end
    overhaul_career_garage_inventory.updatePartConditions(nil, inventoryId, function()
      helpers.spawnVehicle(inventoryId, 2)
    end)
  end

  -- Freeroam race records -------------------------------------------------------------------------

  local lastRaceName = nil
  local lastRaceTime = nil
  local consecutiveRaceCount = 0

  local function isPositiveFinite(value)
    return type(value) == "number" and value > 0 and value < math.huge
  end

  local function recordBestScore(vehicle, raceName, time, driftScore, scoreMode, previousResult)
    local isDrift = scoreMode == true or (driftScore and driftScore ~= 0)
    local score = isDrift and driftScore or time
    local best = vehicle.FRETimes[raceName]
    if not isPositiveFinite(best) then best = nil end
    -- Legacy zero-point runs wrote elapsed time here. Recover retained points
    -- from the prior leaderboard result, but never infer lost points from time.
    if isDrift and previousResult and next(previousResult) ~= nil then
      local previousScore = tonumber(previousResult.driftScore)
      if not isPositiveFinite(previousScore) then
        best = nil
      elseif not best or best < previousScore then
        best = previousScore
      end
    end
    if best then
      score = isDrift and math.max(best, score) or math.min(best, score)
    end
    vehicle.FRETimes[raceName] = score
  end

  local function recordConsecutiveRun(completions, raceName, time)
    if lastRaceName == raceName then
      local pausedTimeSeconds = overhaul_career_economy_pauseTime.getTotalPauseTime()
      local elapsedRaceTimeSeconds = time + pausedTimeSeconds
      if lastRaceTime and os.time() - lastRaceTime < elapsedRaceTimeSeconds + 10 then
        consecutiveRaceCount = consecutiveRaceCount + 1
        if not completions.consecutive or completions.consecutive < consecutiveRaceCount then
          completions.consecutive = consecutiveRaceCount
        end
      end
      lastRaceTime = os.time()
    else
      lastRaceName = raceName
      lastRaceTime = os.time()
      consecutiveRaceCount = 1
      if not completions.consecutive then completions.consecutive = 1 end
    end
  end

  local function saveFRETimeToVehicle(raceName, inventoryId, time, driftScore, scoreMode, previousResult)
    local vehicle = vehicles[inventoryId]
    if not vehicle then return end
    vehicle.FRETimes = vehicle.FRETimes or {}
    vehicle.FRECompletions = vehicle.FRECompletions or {}
    recordBestScore(vehicle, raceName, time, driftScore, scoreMode, previousResult)
    vehicle.FRECompletions[raceName] = vehicle.FRECompletions[raceName] or {}
    vehicle.FRECompletions[raceName].total = (vehicle.FRECompletions[raceName].total or 0) + 1
    recordConsecutiveRun(vehicle.FRECompletions[raceName], raceName, time)
    overhaul_career_economy_pauseTime.resetPauseTime()
  end

  local function getFRETimeToVehicle(raceName, inventoryId)
    local vehicle = vehicles[inventoryId]
    if not vehicle then return nil end
    return vehicle.FRETimes and vehicle.FRETimes[raceName] or nil
  end

  local function getFRECompletions(raceName, inventoryId)
    local vehicle = vehicles[inventoryId]
    if not vehicle then return nil end
    return vehicle.FRECompletions and vehicle.FRECompletions[raceName] or nil
  end

  -- Garage storage --------------------------------------------------------------------------------

  -- Books a vehicle that stands in the current garage into it; false when it cannot be stored.
  local function assignVehicleToGarage(inventoryId, vehicle, garage, inGarage)
    if not inGarage then
      ui_message("Vehicle must be in the current garage to store it.", nil, "vehicleInventory")
      return false
    end
    local spaceInfo = overhaul_career_garage_garageManager.isGarageSpace(garage.id, inventoryId)
    if spaceInfo and spaceInfo[1] then
      vehicle.location = garage.id
      vehicle.lastKnownLevel = getCurrentLevelIdentifier()
      vehicle.niceLocation = overhaul_career_garage_garageManager.garageIdToName(garage.id)
      return true
    end
    ui_message("This garage is full.", nil, "vehicleInventory")
    return false
  end

  local function storeVehicleAtClosestGarage(inventoryId)
    local delivery = overhaul_career_logistics_general
    if not delivery.canRemoveLogisticsVehicle(inventoryId) then return false end
    local vehicle = vehicles[inventoryId]
    if not vehicle then return false end
    if helpers.isVehicleListedForAuction(inventoryId) then return false end
    local garage = inputs.getInventoryMenuGarage()
    if not garage or not garage.id then return false end

    local inGarage = helpers.getVehiclesInGarage(garage, true)[inventoryId]
    local alreadyAssigned = vehicle.location == garage.id
    local hasSpace = overhaul_career_garage_garageManager.isGarageSpace(garage.id, inventoryId)[1]
    if not alreadyAssigned or not hasSpace then
      if not assignVehicleToGarage(inventoryId, vehicle, garage, inGarage) then return false end
    elseif inventoryIdToVehId[inventoryId] and not inGarage then
      inputs.useVehicleRetrievalService(inventoryId, inputs.getLocalGarageRetrievalRoutePrice(), "Towed vehicle into storage")
    end

    vehicle.lastKnownLevel = getCurrentLevelIdentifier()
    vehicle.worldPosition = nil
    if M.clearCarriedPlacement then M.clearCarriedPlacement(inventoryId) end
    helpers.removeVehicleObject(inventoryId)
    helpers.sendDataToUi()
    overhaul_career_garage_computer.refreshMenu(true)
    return true
  end

  -- Public API ------------------------------------------------------------------------------------

  return {
    debugRespawnCurrentVehicle = debugRespawnCurrentVehicle,
    delayVehicleAccess = delayVehicleAccess,
    expediteRepairFromInventory = expediteRepairFromInventory,
    getDirtiedVehicles = getDirtiedVehicles,
    getFRECompletions = getFRECompletions,
    getFRETimeToVehicle = getFRETimeToVehicle,
    getFavoriteVehicle = getFavoriteVehicle,
    getLicensePlateCost = getLicensePlateCost,
    getLicensePlateText = getLicensePlateText,
    getVehicle = getVehicle,
    getVehicleTimeToAccess = getVehicleTimeToAccess,
    getVehicles = getVehicles,
    isEmpty = isEmpty,
    isLicensePlateValid = isLicensePlateValid,
    isVehicleNameValid = isVehicleNameValid,
    onAvailableMissionsSentToUi = onAvailableMissionsSentToUi,
    onGetRawPoiListForLevel = onGetRawPoiListForLevel,
    onOverhaulCheckPermission = onOverhaulCheckPermission,
    onOverhaulComputerAddFunctions = onOverhaulComputerAddFunctions,
    purchaseLicensePlateText = purchaseLicensePlateText,
    recoverPlayerAfterCompanyReturn = recoverPlayerAfterCompanyReturn,
    renameVehicle = renameVehicle,
    returnLoanedVehicleFromInventory = returnLoanedVehicleFromInventory,
    saveFRETimeToVehicle = saveFRETimeToVehicle,
    sellVehicle = sellVehicle,
    sellVehicleFromInventory = sellVehicleFromInventory,
    setFavoriteVehicle = setFavoriteVehicle,
    setLicensePlateText = setLicensePlateText,
    storeVehicleAtClosestGarage = storeVehicleAtClosestGarage,
    bindInputs = function(inputs)
      helpers.ensureGameCameraWithRetry = inputs.ensureGameCameraWithRetry
      helpers.enterVehicle = inputs.enterVehicle
      helpers.getCurrentVehicle = inputs.getCurrentVehicle
      helpers.getInitialRepairTime = inputs.getInitialRepairTime
      helpers.getInventoryIdFromVehicleId = inputs.getInventoryIdFromVehicleId
      helpers.getVehicleIdFromInventoryId = inputs.getVehicleIdFromInventoryId
      helpers.getVehicleThumbnail = inputs.getVehicleThumbnail
      helpers.getVehiclesInGarage = inputs.getVehiclesInGarage
      helpers.hasFreeSlot = inputs.hasFreeSlot
      helpers.isVehicleListedForAuction = inputs.isVehicleListedForAuction
      helpers.openMenuFromComputer = inputs.openMenuFromComputer
      helpers.removeVehicle = inputs.removeVehicle
      helpers.removeVehicleObject = inputs.removeVehicleObject
      helpers.sendDataToUi = inputs.sendDataToUi
      helpers.setVehicleDirty = inputs.setVehicleDirty
      helpers.spawnVehicle = inputs.spawnVehicle
      helpers.teleportWalkFallback = inputs.teleportWalkFallback
      helpers.updatePartConditions = inputs.updatePartConditions
    end,
  }
end

return operations
