-- Vehicle painting: paint previews, prices and purchase settlement.
-- The stock fork keeps the preview vehicle and its career or business paint target together.
-- Map: prices, target lookup, session startup, preview restoration, payment, UI and lifecycle hooks.
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/painting.lua (BeamNG 0.40).

local M = {}

local capabilities = require("overhaul/lib/platform/capabilities")
local checkout = require("overhaul/lib/checkout/operations")
local saveStore = require("overhaul/lib/save/store")

local blockedInputActions = core_input_actionFilter.createActionTemplate({"walkingMode", "bigMap"})

local session
local cleanup

local inventoryId

-- When set, painting operates on a business fleet vehicle instead of the
-- player's career inventory. The paint UI is identical; only the data source,
-- payment method and save target differ.
-- Shape: { businessId=string|number, vehicleId=string|number, vehObjId=number }
local businessCtx

local originComputerId
local chosenPaints
local chosenPackage
local walkingPositionBefore
local previousDefaultRotation

local prices = {
  basePrices = {
    factory = {money = {amount = 600, canBeNegative = false}},
    semiGloss = {money = {amount = 1000, canBeNegative = false}},
    gloss = {money = {amount = 1500, canBeNegative = false}},
    semiMetallic = {money = {amount = 1500, canBeNegative = false}},
    metallic = {money = {amount = 2500, canBeNegative = false}},
    matte = {money = {amount = 1800, canBeNegative = false}},
    chrome = {money = {amount = 3400, canBeNegative = false}},
    custom = {money = {amount = 4000, canBeNegative = false}},
  },
  clearcoatBase = {money = {amount = 500, canBeNegative = false}},
  clearcoatPolishFactor = {money = {amount = 1000, canBeNegative = false}},
}

local colorClassData = {
  semiGloss = {metallic = 0, roughness = 0.13},
  gloss = {metallic = 0, roughness = 0},
  semiMetallic = {metallic = 0.5, roughness = 0.5},
  metallic = {metallic = 1, roughness = 0.5},
  matte = {metallic = 0, roughness = 0.7},
  chrome = {metallic = 1, roughness = 0}
}

local function getPrimerColor()
  local brightnessOffset = (math.random() * 2 - 1) * 0 -- no randomness for now
  local paint = {
    baseColor = {0.58 + brightnessOffset, 0.58 + brightnessOffset, 0.585 + brightnessOffset},
    clearcoat = 0,
    clearcoatRoughness = 1,
    metallic = 0,
    roughness = 0.475,
  }

  return paint
end

local function findBaseColors(partConditions)
  local colors
  for partPath, partCondition in pairs(partConditions) do
    if not colors then
      if partCondition.visualState and partCondition.visualState.paint and partCondition.visualState.paint.originalPaints then
        colors = partCondition.visualState.paint.originalPaints
      end
    end
    if string.find(partPath, "body") then
      if partCondition.visualState and partCondition.visualState.paint and partCondition.visualState.paint.originalPaints then
        return partCondition.visualState.paint.originalPaints
      end
    end
  end
  return colors
end

local function getBusinessVehicleRecord()
  if not businessCtx then return nil end
  return capabilities.get("businessVehicles").getVehicleById(businessCtx.businessId, businessCtx.vehicleId)
end

local function getBusinessVehObj()
  if not businessCtx then return nil end
  return businessCtx.vehObjId and getObjectByID(businessCtx.vehObjId) or nil
end

-- Pricing policy (one place): every cart line is its base price times the economy index, rounded to whole
-- money; the charge is the sum of those rounded lines. The UI shows these exact lines, so the cart always adds up.
local function economyIndex()
  return overhaul_career_economy_globalEconomy.getGlobalIndex() or 1.0
end

local function scaledMoney(amount)
  return math.floor(amount * economyIndex() + 0.5)
end

local function getPriceLines(package)
  local lines = {}
  for index, paintOptions in ipairs(package or {}) do
    if not tableIsEmpty(paintOptions) then
      local base = prices.basePrices[paintOptions.paintClass]
      if base then
        table.insert(lines, {paintIndex = index, kind = "paint", amount = scaledMoney(base.money.amount)})
      end
      if paintOptions.clearCoat then
        table.insert(lines, {paintIndex = index, kind = "clearcoat", amount = scaledMoney(prices.clearcoatBase.money.amount)})
        local polish = tonumber(paintOptions.clearCoatPolish) or 0
        table.insert(lines, {paintIndex = index, kind = "polish", amount = scaledMoney(polish * prices.clearcoatPolishFactor.money.amount)})
      end
    end
  end
  return lines
end

local function getPaintData()
  local data = {}
  local partConditions
  if businessCtx then
    local record = getBusinessVehicleRecord()
    partConditions = record and record.partConditions or {}
  else
    local vehicleInfo = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    partConditions = vehicleInfo.partConditions
  end
  local colors = findBaseColors(partConditions)
  data.colors = colors
  -- unit prices for labels ("Add Clear Coat (Baseprice: ...)"), scaled and rounded by the same rule as the cart lines
  local shownPrices = deepcopy(prices)
  local function scale(t)
    for _, v in pairs(t) do
      if type(v) == "table" then
        if type(v.amount) == "number" then v.amount = scaledMoney(v.amount) else scale(v) end
      end
    end
  end
  scale(shownPrices)
  data.prices = shownPrices
  data.colorClassData = colorClassData
  return data
end

local function startActual(_originComputerId, attempt)
  if attempt and (session ~= attempt or attempt.state ~= "preparing") then return end
  session = attempt or {}
  local active = session
  active.state = "preview"
  chosenPaints = nil
  chosenPackage = nil
  previousDefaultRotation = nil
  originComputerId = _originComputerId
  local ok, opened = pcall(function()
    active.saveHold = saveStore.hold(M, "paint preview", {stage = 'beforeRecovery'})
    if originComputerId or businessCtx then
      local reply = extensions.ui_router.navigate('overhaul.computer.painting')
      if not reply or reply.success ~= true then return false end
    end

    if gameplay_walk.isWalking() then
      walkingPositionBefore = getPlayerVehicle(0):getPosition()
    end

    core_input_actionFilter.setGroup('paintingBlockedActions', blockedInputActions)
    core_input_actionFilter.addAction(0, 'paintingBlockedActions', true)
    guihooks.trigger("onCareerPaintingStarted")
    return true
  end)
  if ok and opened then return true end

  cleanup()
  if not ok then log("E", "painting", "Unable to open painting: " .. tostring(opened)) end
  return false, "paintingUnavailable"
end

local function start(_inventoryId, _originComputerId)
  if session and session.state ~= "closed" then return false end
  if overhaul_career_saveSystem.isSaveBusy() then
    ui_message('Saving is in progress. Try painting again when it finishes.', 5, 'Painting', 'warning')
    return false, 'saveInProgress'
  end
  -- Ensure we're starting clean; a biz session must not leak into a player session.
  businessCtx = nil
  inventoryId = _inventoryId or overhaul_career_garage_inventory.getInventoryIdsInClosestGarage(true)
  if not inventoryId or not overhaul_career_garage_inventory.getMapInventoryIdToVehId()[inventoryId] then return end

  local attempt = {state = "preparing"}
  session = attempt
  core_jobsystem.create(function(job)
    overhaul_career_repair_damageManager.saveDamageState(inventoryId)
    job.sleep(0.1)
    startActual(_originComputerId, attempt)
  end, 2)
end

-- The fleet vehicle must be pulled out so previews can operate on its live object.
local function startForBusinessVehicle(businessId, vehicleId, _originComputerId)
  if not businessId or not vehicleId then return false, "badArgs" end
  if session and session.state ~= "closed" then return false, "paintingActive" end
  if overhaul_career_saveSystem.isSaveBusy() then
    ui_message('Saving is in progress. Try painting again when it finishes.', 5, 'Painting', 'warning')
    return false, 'saveInProgress'
  end

  local record = capabilities.get("businessVehicles").getVehicleById(businessId, vehicleId)
  if not record then return false, "noVehicle" end

  local spawnedId = capabilities.get("businessVehicles").getSpawnedVehicleId(businessId, vehicleId)
  if not spawnedId or not getObjectByID(spawnedId) then
    return false, "notPulledOut"
  end

  inventoryId = nil
  businessCtx = {
    businessId = businessId,
    vehicleId = vehicleId,
    vehObjId = spawnedId,
  }
  local opened, reason = startActual(_originComputerId)
  if not opened then businessCtx = nil end
  return opened, reason
end

-- Preview colors also enter the engine's respawn config. Restore both copies before releasing the save hold.
local function restorePreview(active, committed)
  if not active.originalPaints or committed then return end
  local vehicle = getObjectByID(active.vehObjId)
  if not vehicle then return end
  for index, paint in ipairs(active.originalPaints) do
    extensions.core_vehicle_colors.setVehiclePaint(index, deepcopy(paint), active.vehObjId)
  end
  for partPath, paint in pairs(active.originalPartPaints or {}) do
    vehicle:queueLuaCommand(string.format("partCondition.setPartPaints(%q, %s, %s)",
      partPath, serialize(paint.originalPaints), serialize(paint.odometer or 0)))
  end
end

-- Populated by close() for biz-mode sessions so closeMenu() can route back to
-- the business computer UI after businessCtx has been cleared.
local pendingBizReturn

local function closeMenu()
  if pendingBizReturn then
    local info = pendingBizReturn
    pendingBizReturn = nil
    extensions.ui_router.navigate('business-computer', {
      businessType = info.businessType,
      businessId = info.businessId,
    })
  elseif originComputerId then
    local computer = overhaul_world_facilities.getFacility("computer", originComputerId)
    overhaul_career_garage_computer.openMenu(computer)
  else
    overhaul_career_career.closeAllMenus()
  end
end

-- Restores vehicle/camera/input state. Does NOT navigate; the router owns the
-- transition back to career.computer. Safe to call from the UI on unmount.
local function restorePaintingSession(active, committed)
  restorePreview(active, committed)
  local bizMode = businessCtx ~= nil

  if bizMode or not committed then
    -- A cancelled color preview never replaced physics; keep its outgoing damage capture alive.
    local vehObj
    if bizMode then
      vehObj = getBusinessVehObj()
    else
      local vehId = overhaul_career_garage_inventory.getMapInventoryIdToVehId()[inventoryId]
      vehObj = vehId and getObjectByID(vehId)
    end
    if vehObj and core_vehicleBridge and core_vehicleBridge.executeAction then
      core_vehicleBridge.executeAction(vehObj, 'setFreeze', false)
    end
  else
    overhaul_career_garage_inventory.spawnVehicle(inventoryId, 2)
  end

  local camData = core_camera.getCameraDataById(be:getPlayerVehicleID(0))
  if previousDefaultRotation and camData and camData.orbit then
    camData.orbit:setDefaultRotation(previousDefaultRotation)
    camData.orbit:init()
  end

  if walkingPositionBefore then
    local vehPos = getPlayerVehicle(0):getPosition()
    core_vehicleBridge.executeAction(getPlayerVehicle(0),'setFreeze', false)
    gameplay_walk.setWalkingMode(true, walkingPositionBefore, quatFromDir(vehPos - walkingPositionBefore))
    walkingPositionBefore = nil
  end

  core_input_actionFilter.setGroup('paintingBlockedActions', blockedInputActions)
  core_input_actionFilter.addAction(0, 'paintingBlockedActions', false)
  scenetree.OnlyGui:setFrustumCameraCenterOffset(Point2F(0, 0))
end

cleanup = function()
  local active = session
  if not active or active.state == "closed" or active.state == "closing" or active.state == "paying" then return end
  if active.state == "preparing" then active.state = "closed"; return end
  local committed = active.state == "committed"
  active.state = "closing"
  local ok, err = pcall(restorePaintingSession, active, committed)
  active.state = "closed"
  -- Camera or routing failures must not retain a career-wide save hold.
  local hold = active.saveHold
  active.saveHold = nil
  if hold then hold.release() end
  if not ok then log("E", "painting", "Unable to restore painting session: " .. tostring(err)) end
  return ok
end

local closeMenuAfterSaving
local function close(_closeMenuAfterSaving)
  if not session or session.state == "closed" or session.state == "paying" then return end

  -- decide before cleanup() runs; business vehicles return to the business computer straight away
  local bizMode = businessCtx ~= nil
  closeMenuAfterSaving = (not bizMode) and overhaul_career_career.isAutosaveEnabled() and _closeMenuAfterSaving

  cleanup()

  if bizMode then
    -- Stash info for closeMenu() so we can navigate back to the biz computer
    -- after businessCtx is cleared. Racing Team is the only supported type today.
    pendingBizReturn = {
      businessId = businessCtx.businessId,
      businessType = "racingTeam",
    }
    businessCtx = nil
  end

  if not closeMenuAfterSaving then
    closeMenu()
  end
end

local function onOverhaulSaveFinished()
  if closeMenuAfterSaving then
    closeMenu()
    closeMenuAfterSaving = nil
  end
end

local function getTotalPrice(package)
  -- the charge is the sum of the rounded cart lines (see getPriceLines), never a separately rounded total
  local total = {money = {amount = 0, canBeNegative = false}}
  for _, line in ipairs(getPriceLines(package)) do
    total.money.amount = total.money.amount + line.amount
  end
  return total
end

-- Reentrant UI callbacks cannot change the quote or settle the same session twice.
local function settlePaintPurchase(operation, charge)
  session.state = "paying"
  local ok, paid = pcall(checkout.settle, operation, charge)
  if not ok then log("E", "painting", "Paint payment failed: " .. tostring(paid)) end
  session.state = ok and paid == true and "committed" or "preview"
  return session.state == "committed"
end

local function apply()
  if not session or session.state ~= "preview" or session.capturePending or not chosenPaints then return false end
  local price = getTotalPrice(chosenPackage)
  if not price or not price.money or price.money.amount <= 0 then
    ui_message('Choose a paint finish with a price before purchasing.', 5, 'Painting', 'warning')
    return false
  end

  if businessCtx then
    local record = chosenPaints and getBusinessVehicleRecord()
    if chosenPaints and not record then
      log("W", "painting", "Business vehicle record missing; repaint not charged")
      close()
      return
    end
    -- Charge the business account directly. We use racingTeamFinances for the
    -- debit so the Paint cost shows up in the finance widget ledger.
    local amount = math.max(0, math.floor((price and price.money and price.money.amount) or 0))
    local operation = checkout.begin("painting", {amount = amount, payer = checkout.business(businessCtx.businessId), target = {inventoryId = inventoryId}})
    local ok = settlePaintPurchase(operation, function()
      return checkout.money.execute(overhaul_career_business_racingTeam_finances.tryDebitVehiclePaintCost, businessCtx.businessId, amount)
    end)
    if not ok then return end
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')

    if chosenPaints then
      if record then
        record.config = record.config or {}
        record.config.paints = deepcopy(chosenPaints)
        if record.partConditions then
          for _, partCondition in pairs(record.partConditions) do
            if partCondition.visualState and partCondition.visualState.paint and partCondition.visualState.paint.originalPaints then
              partCondition.visualState.paint.odometer = 0
              partCondition.visualState.paint.originalPaints = deepcopy(chosenPaints)
            end
          end
        end
      end
    end

    close()
    saveStore.request("painting:apply", nil, {force = true})
    return true
  end

  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if chosenPaints and not (vehicle and vehicle.config) then
    log("W", "painting", "Inventory vehicle missing; repaint not charged: " .. tostring(inventoryId))
    close()
    return
  end
  if not overhaul_career_economy_payment.canPay(price) then return end
  local operation = checkout.begin("painting", {amount = price and price.money and price.money.amount, target = {inventoryId = inventoryId}})
  local paid = settlePaintPurchase(operation, function()
    return checkout.money.execute(overhaul_career_economy_payment.pay, price, {category = "purchase", finance = {vehicleId = inventoryId}, label = _tr("ui.career.painting.payment.repaintedVehicle"), tags = {"vehiclePainting", "buying"}})
  end)
  if not paid then return false end
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')

  if chosenPaints then
    vehicle.config.paints = deepcopy(chosenPaints)
    local partPathToPartId = overhaul_career_parts_partInventory.getPartPathToPartIdMap()[inventoryId] or {}
    for partPath, partCondition in pairs(vehicle.partConditions or {}) do
      if partCondition.visualState and partCondition.visualState.paint and partCondition.visualState.paint.originalPaints then
        -- TODO this always sets the odometer of all 3 paints back to 0
        partCondition.visualState.paint.odometer = 0
        partCondition.visualState.paint.originalPaints = chosenPaints

        local partId = partPathToPartId[partPath]
        if partId and overhaul_career_parts_partInventory.getInventory()[partId] then
          overhaul_career_parts_partInventory.getInventory()[partId].primered = nil
        end
      end
    end
  end

  gameplay_achievement.unlockAchievement("VEHICLE_MODIFIED")
  close()
  overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
  saveStore.request("painting:apply", {inventoryId}, {force = true})
  return true
end

local function onOverhaulComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["painting"] then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
    local computerFunctionData = {
      id = "painting",
      routeTarget = "overhaul.computer.painting",
      label = _tr("ui.career.shared.pathPainting"),
      callback = function() start(vehicleData.inventoryId, menuData.computerFacility.id) end,
      order = 15
    }
    -- tutorial active
    if not menuData.hasBoughtStarterVehicle then
      computerFunctionData.disabled = true
      computerFunctionData.reason = overhaul_career_garage_computer.reasons.hasBoughtStarterVehicle
    end

    -- generic gameplay reason
    local inventoryId = vehicleData.inventoryId
    local reason =  overhaul_career_permissions.getStatusForTag({"painting", "vehicleModification"}, {inventoryId = inventoryId})
    if not reason.allow then
      computerFunctionData.disabled = true
    end
    if reason.permission ~= "allowed" then
      computerFunctionData.reason = reason
    end

    computerFunctions.vehicleSpecific[inventoryId][computerFunctionData.id] = computerFunctionData
  end
end

local function businessCanAfford(amount)
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  if amount <= 0 then return true end
  if not businessCtx then return false end
  local account = overhaul_career_economy_bank.getBusinessAccount("racingTeam", businessCtx.businessId)
  if not account then return false end
  local balance = tonumber(account.balance) or 0
  return balance >= amount
end

local function sendShoppingCartData(package)
  local data = {}
  data.totalPrice = getTotalPrice(package)
  data.priceLines = getPriceLines(package)
  if businessCtx then
    data.canPay = businessCanAfford(data.totalPrice and data.totalPrice.money and data.totalPrice.money.amount or 0)
  else
    data.canPay = overhaul_career_economy_payment.canPay(data.totalPrice)
  end
  guihooks.trigger("sendPaintingShoppingCartData", data)
end

local function setPaints(paints, paintOptions, partName)
  if not session or session.state ~= "preview" or type(paints) ~= "table" or not paints[1]
      or type(paintOptions) ~= "table" then return false end
  chosenPaints = deepcopy(paints)
  chosenPackage = deepcopy(paintOptions)

  sendShoppingCartData(chosenPackage)

  if tableSize(chosenPaints) < 3 then
    for i = tableSize(chosenPaints)+1, 3 do
      chosenPaints[i] = chosenPaints[i-1]
    end
  end

  local vehObjId
  local vehicleObject
  if businessCtx then
    vehObjId = businessCtx.vehObjId
    vehicleObject = getBusinessVehObj()
  else
    vehObjId = overhaul_career_garage_inventory.getMapInventoryIdToVehId()[inventoryId]
    vehicleObject = getObjectByID(vehObjId)
  end
  if not vehicleObject then return end
  local active = session
  active.partName = partName
  local function preview()
    if session ~= active or active.state ~= "preview" then return end
    for index = 1, 3 do
      extensions.core_vehicle_colors.setVehiclePaint(index, deepcopy(chosenPaints[index]), vehObjId)
    end
    if active.partName then
      vehicleObject:queueLuaCommand(string.format("partCondition.setPartPaints(%q, %s, 0)", active.partName, serialize(chosenPaints)))
    else
      vehicleObject:queueLuaCommand(string.format("partCondition.setAllPartPaints(%s, 0)", serialize(chosenPaints)))
    end
  end
  if active.capturePending then return end
  if active.originalPaints then preview(); return end
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehObjId)
  if not vehicleData or not vehicleData.config or not vehicleData.config.paints then return false end
  active.vehObjId = vehObjId
  active.originalPaints = deepcopy(vehicleData.config.paints)
  -- A newly owned vehicle can share this config with its inventory record.
  vehicleData.config = deepcopy(vehicleData.config)
  for index = #active.originalPaints + 1, 3 do
    active.originalPaints[index] = deepcopy(active.originalPaints[index - 1])
  end
  active.capturePending = true
  local capture = {}
  active.paintCapture = capture
  local function captureFailed()
    if session ~= active or active.paintCapture ~= capture then return end
    active.capturePending, active.paintCapture = false, nil
    active.originalPaints, active.originalPartPaints = nil, nil
    chosenPaints, chosenPackage = nil, nil
    guihooks.trigger("toastrMsg", {type = "error", title = "Painting unavailable",
      msg = "The original paint could not be read. Try previewing the paint again."})
  end
  local ok, err = pcall(core_vehicleBridge.requestValue, vehicleObject, function(response)
    if session ~= active or active.state ~= "preview" or active.paintCapture ~= capture then return end
    if not response or type(response.result) ~= "table" then captureFailed(); return end
    active.originalPartPaints = {}
    for path, condition in pairs(response.result) do
      local paint = condition.visualState and condition.visualState.paint
      if paint and paint.originalPaints then active.originalPartPaints[path] = deepcopy(paint) end
    end
    active.capturePending, active.paintCapture = false, nil
    preview()
  end, 'getPartConditions')
  if not ok then
    captureFailed()
    log("E", "painting", "Unable to capture original paint: " .. tostring(err))
  end
end

local function getFactoryPaint()
  local id
  if businessCtx then
    id = businessCtx.vehObjId
  else
    id = overhaul_career_garage_inventory.getMapInventoryIdToVehId()[inventoryId]
  end
  if not id then return {} end
  local info = core_vehicles.getVehicleDetails(id)
  return info.model and info.model.paints or {}
end

local function sendPaintingDataToUI()
  if not session or session.state ~= "preview" then return end
  local data = getPaintData()
  data.factoryPaint = getFactoryPaint()
  guihooks.trigger("paintingData", data)
end

-- Router lifecycle: re-emit the painting data once the destination view has mounted.
local function onRouteMount(context, toRoute, fromRoute, data)
  sendPaintingDataToUI()
end

local function onUIOpened()
  local active = session
  if not active or active.state ~= "preview" then return end
  local vehId
  if businessCtx then
    vehId = businessCtx.vehObjId
  else
    vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  end
  if not vehId then return end
  local veh = getObjectByID(vehId)
  if not veh then return end
  core_vehicleBridge.requestValue(veh, function()
    if session ~= active or active.state ~= "preview" then return end
    if businessCtx then
      -- Switch camera/focus to the biz vehicle (it's already spawned/parked).
      be:enterVehicle(0, veh)
    else
      overhaul_career_garage_inventory.enterVehicle(inventoryId)
    end
    core_vehicleBridge.executeAction(veh,'setFreeze', true)

    -- we use setDefaultRotation instead of setRotation, because that one doesnt work reliably
    local vehCamData = core_camera.getCameraDataById(be:getPlayerVehicleID(0)).orbit
    if vehCamData then
      previousDefaultRotation = vehCamData.defaultRotation
    end
    core_camera.setByName(0, "orbit", true)
    core_camera.setDefaultRotation(vehId, vec3(145, -15, 0))
    core_camera.resetCamera(0)
    scenetree.OnlyGui:setFrustumCameraCenterOffset(Point2F(-0.3125, 0))
    extensions.hook("onOverhaulVehiclePaintingUiOpened")
  end, 'ping')
end

M.start = start
M.startForBusinessVehicle = startForBusinessVehicle
M.apply = apply
M.close = close
M.cleanup = cleanup
M.getPaintData = getPaintData
M.setPaints = setPaints
M.getFactoryPaint = getFactoryPaint
M.sendPaintingDataToUI = sendPaintingDataToUI

M.getPrimerColor = getPrimerColor

M.onOverhaulComputerAddFunctions = onOverhaulComputerAddFunctions
M.onUIOpened = onUIOpened
M.onRouteMount = onRouteMount
M.onOverhaulSaveFinished = onOverhaulSaveFinished
M.onExtensionUnloaded = cleanup

return M
