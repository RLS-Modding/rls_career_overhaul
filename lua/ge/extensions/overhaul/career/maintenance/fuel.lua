-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/fuel.lua (BeamNG 0.40).
-- Runs station refueling, energy-unit conversion, payment and sounds for the current career transaction.
-- The RLS business, employer and seated-car rules live in fuel/fuelSeam.lua.

local M = {}

local imgui = ui_imgui
-- RLS seam (overhaul/career/maintenance/fuel/fuelSeam.lua): the vehicle the pump serves, business and
-- shop-stockpile refuels, employer-paid company cars. Lines marked "RLS" differ from stock.
local fuelSeam = require('overhaul/career/maintenance/fuel/fuelSeam')
local careerFuelContext = fuelSeam.create()

local maxFuelFlowRateJoulesPerSecond = 50000000
local fuelFlowRateJoulesPerSecond = maxFuelFlowRateJoulesPerSecond

local fuelData
local transaction
local fuelingActive = {}
local energyTypeFuelingActive = {}
local energyTypes = {}
local defaultEnergyType
local selectedTankIndex = 1

local startingFuelData
local fuelingData = {}
local overallPrice = 0

local gasSoundId
local electricSoundId

local isSoundPlaying = {}

local showUI

local gasStation -- The gasstation where the refueling was started
local fuelDiscountData = {} -- Store discount data for the current transaction
local debugIgnoreStationFuelTypeRestriction = false

local megajoulesPerReadableUnit = {
  gasoline = 31.125,
  diesel = 36.112,
  kerosine = 34.4,
  n2o = 8.3,
  electricEnergy = 3.6
}

local readableUnit = {
  gasoline = "L",
  diesel = "L",
  kerosine = "L",
  n2o = "kg",
  electricEnergy = "kWh"
}

local isCurrentlyFueling

local function setDefaultEnergyType(energyType)
  defaultEnergyType = energyType
end

local function jouleToReadableUnit(energyJoules, fuelType)
  return energyJoules / 1000000 / megajoulesPerReadableUnit[fuelType]
end

local function initializeDefaultEnergyType()
  local defaultTypeCandidate

  -- if the vehicle has one of these types, use this as default
  for i, energyType in ipairs(energyTypes) do
    if energyType == "gasoline" or energyType == "diesel" or energyType == "kerosine" then
      defaultTypeCandidate = energyType
      break
    end
  end

  if not defaultTypeCandidate then
    for i, energyType in ipairs(energyTypes) do
      if energyType == "electricEnergy" then
        defaultTypeCandidate = energyType
        break
      end
    end
  end

  setDefaultEnergyType(defaultTypeCandidate)
end

local function getPricePerUnit(energyType)
  local shopPrice = fuelSeam.getShopPricePerUnit(gasStation, energyType) -- RLS
  if shopPrice then return shopPrice end -- RLS
  local basePrice = overhaul_world_fuel_fuelPrice.getFuelPrice(gasStation.facility.id, energyType) or 1
  if fuelDiscountData.hasFuelDiscount then
    return basePrice * (1 - fuelDiscountData.fuelDiscount) -- apply insurance discount
  end
  return basePrice
end

local function gasStationOffersFuelType(energyType)
  if fuelSeam.sellsEveryFuelType(gasStation) then return true end -- RLS
  return debugIgnoreStationFuelTypeRestriction or overhaul_world_fuel_fuelPrice.getFuelPrice(gasStation.facility.id, energyType) ~= nil
end

local function getCurrentVehicleData()
  local currentVehicleId = careerFuelContext.resolvePlayerInventoryId() -- RLS
  return currentVehicleId and overhaul_career_garage_inventory.getVehicles()[currentVehicleId]
end

local function canPayPrice()
  if overallPrice <= 0 then return false end
  if careerFuelContext.isBusinessTransaction() then return true end -- RLS: billed to the business (personal fallback)
  local currentVehicle = getCurrentVehicleData()
  if currentVehicle and (currentVehicle.loanType == "work" or careerFuelContext.isEmployerVehicleOnShift(currentVehicle)) then return true end
  return overallPrice <= overhaul_career_economy_playerAttributes.getAttributeValue("money")
end

local function sendInitialDataToUI()
  local levelInfoData = core_levels.getLevelByName(getCurrentLevelIdentifier())
  local localUnits = {}
  if levelInfoData then
    localUnits = levelInfoData.localUnits or {}
  end

  -- check for fuel discount via the current insurance
  fuelDiscountData = {}
  if overhaul_career_career.isActive() then
    local currentVehicleId = careerFuelContext.resolvePlayerInventoryId() -- RLS
    if currentVehicleId then
      fuelDiscountData = overhaul_career_repair_insurance.getInvVehFuelDiscountData(currentVehicleId)
    end
  end


  local uiUpdateData = {}
  uiUpdateData.energyTypesToLocalUnits = localUnits
  uiUpdateData.energyTypes = energyTypes
  uiUpdateData.selectedTankIndex = selectedTankIndex
  uiUpdateData.gasStationName = gasStation.facility.name
  uiUpdateData.fuelData = {}
  for i, tank in ipairs(fuelData) do
    local tankData = {}
    tankData.energyType = tank.energyType
    fuelSeam.tagTank(tankData, tank, i) -- RLS
    tankData.currentEnergy = jouleToReadableUnit(tank.currentEnergy, tank.energyType)
    tankData.maxEnergy = jouleToReadableUnit(tank.maxEnergy, tank.energyType)
    tankData.pricePerUnit = getPricePerUnit(tank.energyType)
    uiUpdateData.fuelData[i] = tankData
  end

  if fuelDiscountData.hasFuelDiscount then
    uiUpdateData.fuelDiscountData = fuelDiscountData
  end

  guihooks.trigger('initialFuelingData', uiUpdateData)
end

local function sendUpdateDataToUI()
  local uiUpdateData = {}
  uiUpdateData.fuelData = {}
  uiUpdateData.overallPrice = overallPrice
  uiUpdateData.canPay = canPayPrice()
  for i, tank in ipairs(fuelData) do
    local tankData = {}
    fuelSeam.tagTank(tankData, tank, i) -- RLS
    tankData.currentEnergy = jouleToReadableUnit(tank.currentEnergy, tank.energyType)
    tankData.fueledEnergy = jouleToReadableUnit(fuelingData[i].fueledEnergy, tank.energyType)
    tankData.price = fuelingData[i].price
    tankData.fuelingActive = fuelingActive[i]
    uiUpdateData.fuelData[i] = tankData
  end
  uiUpdateData.flowRate = fuelFlowRateJoulesPerSecond / maxFuelFlowRateJoulesPerSecond

  guihooks.trigger('updateFuelData', uiUpdateData)
end

local function saveEnergyStorageData(data)
  fuelData = {}
  for _, tank in ipairs(data[1]) do
    -- only add tanks that this station can actually fill
    if megajoulesPerReadableUnit[tank.energyType] and gasStationOffersFuelType(tank.energyType) then
      table.insert(fuelData, tank)
    end
  end
  showUI = true
  selectedTankIndex = 1
  defaultEnergyType = fuelData[selectedTankIndex] and fuelData[selectedTankIndex].energyType or nil
  for i, data in ipairs(fuelData) do
    table.insert(fuelingData, {price = 0, fueledEnergy = 0})
  end

  table.clear(energyTypes)
  for index, tankData in ipairs(fuelData) do
    if not tableContains(energyTypes, tankData.energyType) then
      table.insert(energyTypes, tankData.energyType)
    end
  end
  sendInitialDataToUI()
end

local function requestEnergyStorageData()
  if not transaction or fuelData then return end
  local requestedTransaction = transaction
  local veh = careerFuelContext.getFuelingVehicle() -- RLS
  core_vehicleBridge.requestValue(veh, function(data)
    -- Replies can arrive after cancel or after another visit to the pump.
    if transaction ~= requestedTransaction or fuelData then return end
    saveEnergyStorageData(data)
  end, 'energyStorage')
end

local function startAngularUI()
  extensions.ui_router.navigate("overhaul.refueling")
end

local function requestRefuelingTransactionData()
  requestEnergyStorageData()
end

local function startTransaction(_gasStation, vehObjId) -- RLS: vehObjId, the car the player walked up to
  if transaction then return end
  if not careerFuelContext.beginTransaction(vehObjId) then return end -- RLS
  transaction = {}
  gasStation = _gasStation
  careerFuelContext.showStationPrices() -- RLS
  pushActionMap("Refueling")
  local txVeh = careerFuelContext.getFuelingVehicle() -- RLS
  if txVeh then core_vehicleBridge.executeAction(txVeh, 'setIgnitionLevel', 0) end -- RLS
  startAngularUI()
  extensions.hook("onOverhaulRefuelingStartTransaction")
end

local function getFuelData()
  return fuelData
end

local function applyFuelData(data, veh)
  if showUI then
    sendUpdateDataToUI()
  end
  veh = veh or careerFuelContext.getFuelingVehicle() -- RLS
  for index, tankData in ipairs(data or fuelData) do
    core_vehicleBridge.executeAction(veh, 'setEnergyStorageEnergy', tankData.name, tankData.currentEnergy)
  end
end

local function restoreFuelData(data, veh)
  veh = veh or careerFuelContext.getFuelingVehicle() -- RLS
  for index, tankData in ipairs(data or {}) do
    fuelData[index].currentEnergy = tankData.currentEnergy
    core_vehicleBridge.executeAction(veh, 'setEnergyStorageEnergy', tankData.name, tankData.currentEnergy)
  end
end

local function activateSound(soundId, active)
  local sound = scenetree.findObjectById(soundId)
  if sound then
    if active then
      sound:play(-1)
    else
      sound:stop(-1)
    end
    sound:setTransform(getCameraTransform())
    isSoundPlaying[soundId] = active
  end
end

local function getGasFuelLevelInfo()
  local maxVolume = 0
  local currentVolume = 0
  for index, data in ipairs(fuelData) do
    if data.energyType == "gasoline" or data.energyType == "diesel" or data.energyType == "kerosine" then
      currentVolume = currentVolume + data.currentEnergy
      maxVolume = maxVolume + data.maxEnergy
    end
  end
  return currentVolume, maxVolume, maxVolume > 0 and currentVolume / maxVolume or nil
end

local function getRelativeFuelLevel()
  local _, _, relativeFuelLevel = getGasFuelLevelInfo()
  return relativeFuelLevel or 0
end

local function updateFuelSoundParameters()
  local relativeFuelLevel = getRelativeFuelLevel()
  local sound = scenetree.findObjectById(gasSoundId)
  if sound then
    sound:setParameter("volume", relativeFuelLevel)
    sound:setParameter("pitch", fuelFlowRateJoulesPerSecond / maxFuelFlowRateJoulesPerSecond)
    sound:setTransform(getCameraTransform())
  end
end

local function updateFuelingFlags()
  table.clear(energyTypeFuelingActive)
  for i, data in ipairs(fuelingActive) do
    if fuelingActive[i] then
      energyTypeFuelingActive[fuelData[i].energyType] = true
    end
  end

  if energyTypeFuelingActive["gasoline"] or energyTypeFuelingActive["diesel"] or energyTypeFuelingActive["kerosine"] then
    if not isSoundPlaying[gasSoundId] then
      activateSound(gasSoundId, true)
    end
  else
    if isSoundPlaying[gasSoundId] then
      updateFuelSoundParameters()
      activateSound(gasSoundId, false)
    end
  end

  if energyTypeFuelingActive["electricEnergy"] then
    if not isSoundPlaying[electricSoundId] then
      activateSound(electricSoundId, true)
    end
  else
    if isSoundPlaying[electricSoundId] then
      updateFuelSoundParameters()
      activateSound(electricSoundId, false)
    end
  end
end

local function stopFuelingTank(index, applyData)
  fuelingActive[index] = false
  if applyData == nil then applyData = true end
  if applyData then
    updateFuelingFlags()
    applyFuelData()
  end
  extensions.hook("onOverhaulRefuelingStopFueling", fuelData[index])
end

local function startFuelingTank(index)
  if careerFuelContext.hasFuelingTarget() then -- RLS
    local veh = careerFuelContext.getFuelingVehicle() -- RLS
    if not veh then return end -- RLS
    if veh:getVelocity():length() < 1 then
      fuelingActive[index] = true
      startingFuelData = startingFuelData or deepcopy(fuelData)
    end
  end
end

local function startFuelingType(energyType)
  for index, data in ipairs(fuelData) do
    if data.energyType == energyType then
      startFuelingTank(index)
    end
  end
  updateFuelingFlags()
end

local function stopFuelingType(energyType)
  for index, data in ipairs(fuelData) do
    if not energyType or (data.energyType == energyType) then
      stopFuelingTank(index, false)
    end
  end
  updateFuelingFlags()
  applyFuelData()
end

local function getValidTankIndex(index)
  if not fuelData or not next(fuelData) then return nil end
  index = clamp(tonumber(index) or selectedTankIndex or 1, 1, #fuelData)
  return fuelData[index] and index or nil
end

local function onChangeFlowRate(factor, tankIndex)
  if not gasStation then return end
  local validIndex = getValidTankIndex(tankIndex or selectedTankIndex)
  if not validIndex then
    return
  end
  selectedTankIndex = validIndex
  defaultEnergyType = fuelData[selectedTankIndex].energyType

  factor = clamp(factor, 0, 1)
  if factor <= 0 then
    stopFuelingTank(selectedTankIndex)
    fuelFlowRateJoulesPerSecond = maxFuelFlowRateJoulesPerSecond
    return
  end
  fuelFlowRateJoulesPerSecond = maxFuelFlowRateJoulesPerSecond * factor
  if not fuelingActive[selectedTankIndex] and fuelData[selectedTankIndex].currentEnergy < fuelData[selectedTankIndex].maxEnergy then
    startFuelingTank(selectedTankIndex)
    updateFuelingFlags()
    sendUpdateDataToUI()
  end
end

local function getFuelingData()
  return fuelingData
end

local function endTransaction()
  if not transaction then return end
  transaction = nil
  popActionMap("Refueling")
  table.clear(fuelingData)
  table.clear(fuelingActive)
  table.clear(energyTypeFuelingActive)
  table.clear(energyTypes)
  showUI = false
  overallPrice = 0
  startingFuelData = nil
  fuelData = nil
  defaultEnergyType = nil
  selectedTankIndex = 1
  fuelFlowRateJoulesPerSecond = maxFuelFlowRateJoulesPerSecond
  fuelDiscountData = {}
  activateSound(gasSoundId, false)
  activateSound(electricSoundId, false)
  local bizMode = careerFuelContext.isBusinessTransaction() -- RLS
  if overhaul_career_career.isAutosaveEnabled() then
    overhaul_career_saveSystem.saveCurrent()
  elseif not bizMode then -- RLS: business fleet vehicles are not in the inventory
    overhaul_career_garage_inventory.updatePartConditions(nil, careerFuelContext.resolvePlayerInventoryId()) -- RLS
  end

  if not careerFuelContext.finishTransaction() then -- RLS: back to the Business Computer when it started the refuel
    extensions.ui_router.navigate('play')
  end
  extensions.hook("onOverhaulRefuelingEndTransaction")
end

local function payPrice()
  if not canPayPrice() then return end
  if overallPrice > 0 then
    Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  end
  stopFuelingType()
  -- RLS: the achievement unlocks once, after the payment (stock also unlocked it here)

  local paidByBusiness = careerFuelContext.payForBusinessVehicle(function() return overallPrice end, gasStation) -- RLS
  local currentVehicle = not paidByBusiness and getCurrentVehicleData() -- RLS
  if paidByBusiness then -- RLS: billed by the seam
  elseif currentVehicle and (currentVehicle.loanType == "work" or careerFuelContext.isEmployerVehicleOnShift(currentVehicle)) then -- RLS
    ui_message(_tr("ui.career.refueling.paidByCompany"), 6, "refueling")
  else
    overhaul_career_economy_playerAttributes.addAttributes({money=-overallPrice}, {
      category = "fuel",
      finance = {
        vehicleId = careerFuelContext.resolvePlayerInventoryId(),
        vehicleName = currentVehicle and currentVehicle.niceName,
        locationId = gasStation.facility.id, locationName = gasStation.facility.name,
      },
      tags = {"fuel", "buying"},
      label = {
        txt = "ui.career.attributeLog.refuelledAt",
        context = { facilityName = gasStation.facility.name },
      },
    })
    gameplay_statistic.metricAdd("career/fuel/paidPrice.money", overallPrice)
  end

  endTransaction()
  extensions.hook("onOverhaulPaidRefuelling", overallPrice)
  gameplay_achievement.unlockAchievement("VEHICLE_REFUELLED")
end

local function uiSetSelectedTankIndex(index)
  if isCurrentlyFueling() then return end
  local validIndex = getValidTankIndex(index)
  if not validIndex then return end
  selectedTankIndex = validIndex
  defaultEnergyType = fuelData[selectedTankIndex].energyType
end

local function uiButtonStartFueling(energyType)
  startFuelingType(energyType)
end

local function uiButtonStopFueling(energyType)
  stopFuelingType(energyType)
end

local function uiButtonStartFuelingTank(index)
  uiSetSelectedTankIndex(index)
  local validIndex = getValidTankIndex(selectedTankIndex)
  if validIndex then
    startFuelingTank(validIndex)
    updateFuelingFlags()
    sendUpdateDataToUI()
  end
end

local function uiButtonStopFuelingTank(index)
  local validIndex = getValidTankIndex(index)
  if validIndex then
    stopFuelingTank(validIndex, false)
    updateFuelingFlags()
    applyFuelData()
  end
end

local function uiCancelTransaction()
  if not transaction then return end
  if startingFuelData then
    restoreFuelData(startingFuelData)
  end
  endTransaction()
end

function isCurrentlyFueling()
  if fuelData then
    for index, data in ipairs(fuelData) do
      if fuelingActive[index] then
        return true
      end
    end
  end
  return false
end

local function updateOverallPrice()
  overallPrice = 0
  for _, data in ipairs(fuelingData) do
    overallPrice = overallPrice + data.price
  end
end

local function getFuelingEnergyRate(energyType)
  return energyType == "electricEnergy" and fuelFlowRateJoulesPerSecond / 3 or fuelFlowRateJoulesPerSecond
end

local uiFuelDataDeltaCounter = 0
local function onUpdate(dtReal, dtSim)
  if showUI then
    local veh = careerFuelContext.getFuelingVehicle() -- RLS
    if veh and veh:getVelocity():length() > 2 then -- RLS
      uiCancelTransaction()
    end
  end

  if fuelData then
    uiFuelDataDeltaCounter = uiFuelDataDeltaCounter + dtReal

    local applyAndSendToUI = false
    for index, data in ipairs(fuelData) do
      if fuelingActive[index] then
        data.currentEnergy = math.min(data.maxEnergy, data.currentEnergy + dtSim * getFuelingEnergyRate(data.energyType))
        fuelingData[index].fueledEnergy = data.currentEnergy - startingFuelData[index].currentEnergy

        local price = getPricePerUnit(data.energyType) * jouleToReadableUnit(fuelingData[index].fueledEnergy, data.energyType)
        fuelingData[index].price = math.floor((price * 100) + 0.5) / 100
        if data.currentEnergy >= data.maxEnergy then
          -- tank is full
          stopFuelingTank(index, false)
          applyAndSendToUI = true
        end
      end
    end
    updateOverallPrice()

    if applyAndSendToUI then
      updateFuelingFlags()
      applyFuelData()
    elseif isCurrentlyFueling() then
      -- do a regular update for ui
      if uiFuelDataDeltaCounter > 0.1 then
        sendUpdateDataToUI()
        uiFuelDataDeltaCounter = 0
      end
    end
    if energyTypeFuelingActive["gasoline"] or energyTypeFuelingActive["diesel"] or energyTypeFuelingActive["kerosine"] then
      updateFuelSoundParameters()
    end
  end

  if showUI and not shipping_build then
    imgui.SetNextWindowSize(imgui.ImVec2(360, 520), imgui.Cond_FirstUseEver)
    imgui.Begin("Fueling")

    for index, tankData in ipairs(fuelData) do
      if imgui.BeginChild1("Tank " .. index, imgui.ImVec2(0, 175), true) then
        imgui.Text("Tank " .. index)
        imgui.Text(string.format("Fuel Type: %s", tankData.energyType))
        local unit = readableUnit[tankData.energyType]
        imgui.Text(string.format("Energy: %.2f %s / %.2f %s", jouleToReadableUnit(tankData.currentEnergy, tankData.energyType), unit, jouleToReadableUnit(tankData.maxEnergy, tankData.energyType), unit))
        imgui.Text(string.format("Fueled Energy: %.2f %s", jouleToReadableUnit(fuelingData[index].fueledEnergy, tankData.energyType) or 0, unit))
        imgui.Text(string.format("Fueling Active: %s", tostring(fuelingActive[index] == true)))
        imgui.Text(string.format("Fueling Speed: %.2f %s/s", fuelingActive[index] and jouleToReadableUnit(getFuelingEnergyRate(tankData.energyType), tankData.energyType) or 0, unit))

        imgui.Text("Price " .. fuelingData[index].price or 0)
      end
      imgui.EndChild()
    end

    local fuelFlowFactor = maxFuelFlowRateJoulesPerSecond > 0 and fuelFlowRateJoulesPerSecond / maxFuelFlowRateJoulesPerSecond or 0
    imgui.Text(string.format("Fuel Flow Rate: %.0f J/s (%.2f)", fuelFlowRateJoulesPerSecond, fuelFlowFactor))
    imgui.Text(string.format("Currently Fueling: %s", tostring(isCurrentlyFueling())))
    imgui.Text(string.format("Default Energy Type: %s", tostring(defaultEnergyType)))

    local _, _, relativeFuelLevel = getGasFuelLevelInfo()
    local gasSound = gasSoundId and scenetree.findObjectById(gasSoundId) or nil
    local electricSound = electricSoundId and scenetree.findObjectById(electricSoundId) or nil
    imgui.Separator()
    imgui.Text("Refueling Sound")
    imgui.Text(string.format("Gas active: %s", tostring(energyTypeFuelingActive["gasoline"] or energyTypeFuelingActive["diesel"] or energyTypeFuelingActive["kerosine"] or false)))
    imgui.Text(string.format("Gas sound id: %s", tostring(gasSoundId)))
    imgui.Text(string.format("Gas sound object: %s", gasSound and "found" or "missing"))
    imgui.Text(string.format("Gas playing flag: %s", tostring(isSoundPlaying[gasSoundId] == true)))
    imgui.Text(string.format("Gas volume param: %s", relativeFuelLevel and string.format("%.2f", relativeFuelLevel) or "n/a"))
    imgui.Text(string.format("Gas pitch param: %.2f", fuelFlowFactor))
    imgui.Text(string.format("Electric active: %s", tostring(energyTypeFuelingActive["electricEnergy"] or false)))
    imgui.Text(string.format("Electric sound id: %s", tostring(electricSoundId)))
    imgui.Text(string.format("Electric sound object: %s", electricSound and "found" or "missing"))
    imgui.Text(string.format("Electric playing flag: %s", tostring(isSoundPlaying[electricSoundId] == true)))

    for i, energyType in ipairs(energyTypes) do
      if imgui.Button(string.format("Start Fueling %s ##%d", energyType, i)) then
        uiButtonStartFueling(energyType)
      end
      imgui.SameLine()
      if imgui.Button(string.format("Stop Fueling %s ##%d", energyType, i)) then
        uiButtonStopFueling(energyType)
      end
    end

    imgui.Text(string.format("Overall Price: %.2f $", overallPrice))
    if overallPrice <= overhaul_career_economy_playerAttributes.getAttributeValue("money") then
      if imgui.Button(string.format("Pay")) then
        payPrice()
      end
    else
      imgui.Text("Not enough money to pay")
    end
    imgui.End()
  end
end

local function setMinimumFuel(data, veh)
  local tanksData = data[1]
  for i, tank in ipairs(tanksData) do
    -- refuel the car if it is electric or nearly empty
    if tank.energyType == "electricEnergy" then
      tank.currentEnergy = tank.maxEnergy
      ui_message(_tr("ui.career.refueling.emergencyFullyRecharged"), nil, "emergencyRefuel")
    elseif tank.currentEnergy <= tank.maxEnergy * 0.01 then
      tank.currentEnergy = tank.maxEnergy * 0.05
      ui_message(_tr("ui.career.refueling.emergencyPartialRefuel"), nil, "emergencyRefuel")
    end
  end
  applyFuelData(tanksData, veh)
end

local function minimumRefuelingCheck(vehId)
  vehId = vehId or careerFuelContext.currentVehicleId() -- RLS
  if careerFuelContext.skipMinimumRefuel(vehId) then return end -- RLS: recovery-contract targets keep their fuel
  if vehId then
    local veh = getObjectByID(vehId)
    if veh then
      core_vehicleBridge.requestValue(veh, function(data) setMinimumFuel(data, veh) end, 'energyStorage')
    end
  end
end

local function setupSounds()
  gasSoundId = gasSoundId or Engine.Audio.createSource('AudioGui', 'event:>UI>Career>Fueling_Petrol')
  electricSoundId = electricSoundId or Engine.Audio.createSource('AudioGui', 'event:>UI>Career>Fueling_Electric')
end

local function onOverhaulActive(active)
  if not active then return end
  setupSounds()
end

local function onClientEndMission(levelPath)
  gasSoundId = nil
  electricSoundId = nil
end

M.startTransaction = startTransaction
M.startForBusinessVehicle = function(businessId, vehicleId) -- RLS
  return careerFuelContext.startForBusinessVehicle(businessId, vehicleId, startTransaction)
end
M.getFuelData = getFuelData
M.isCurrentlyFueling = isCurrentlyFueling
M.getFuelingData = getFuelingData
M.payPrice = payPrice
M.onChangeFlowRate = onChangeFlowRate

-- Called by UI
M.uiButtonStartFueling = uiButtonStartFueling
M.uiButtonStopFueling = uiButtonStopFueling
M.uiButtonStartFuelingTank = uiButtonStartFuelingTank
M.uiButtonStopFuelingTank = uiButtonStopFuelingTank
M.uiSetSelectedTankIndex = uiSetSelectedTankIndex
M.requestRefuelingTransactionData = requestRefuelingTransactionData
M.uiCancelTransaction = uiCancelTransaction
M.sendUpdateDataToUI = sendUpdateDataToUI

M.onUpdate = onUpdate
M.onOverhaulActive = onOverhaulActive
M.onClientEndMission = onClientEndMission
M.minimumRefuelingCheck = minimumRefuelingCheck

return M
