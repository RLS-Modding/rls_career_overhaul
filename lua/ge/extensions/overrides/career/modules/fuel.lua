-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career'}
local imgui = ui_imgui

local maxFuelFlowRate = 50000000
local fuelFlowRate = maxFuelFlowRate

local fuelData
local fuelingActive = {}
local energyTypeFuelingActive = {}
local energyTypes = {}
local defaultEnergyType

local startingFuelData
local fuelingData = {}
local overallPrice = 0

local gasSoundId
local electricSoundId

local isSoundPlaying = {}

local showUI

local gasStation -- The gasstation where the refueling was started
local fuelDiscountData = {} -- Store discount data for the current transaction

local factorMJToReadable = {
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

local function setDefaultEnergyType(energyType)
  defaultEnergyType = energyType
end

local function jouleToReadableUnit(value, fuelType)
  return value / 1000000 / factorMJToReadable[fuelType]
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
  local basePrice = freeroam_facilities_fuelPrice.getFuelPrice(gasStation.facility.id, energyType) or 1
  if fuelDiscountData.hasFuelDiscount then
    return basePrice * (1 - fuelDiscountData.fuelDiscount) -- apply insurance discount
  end
  return basePrice
end

local function sendInitialDataToUI()
  local levelInfoData = core_levels.getLevelByName(getCurrentLevelIdentifier())
  local localUnits = {}
  if levelInfoData then
    localUnits = levelInfoData.localUnits or {}
  end

  -- check for fuel discount via the current insurance
  fuelDiscountData = {}
  if career_career.isActive() then
    local currentVehicleId = career_modules_inventory.getCurrentVehicle()
    if currentVehicleId then
      fuelDiscountData = career_modules_insurance_insurance.getInvVehFuelDiscountData(currentVehicleId)
    end
  end

  local uiUpdateData = {}
  uiUpdateData.energyTypesToLocalUnits = localUnits
  uiUpdateData.energyTypes = energyTypes
  uiUpdateData.gasStationName = gasStation.facility.name
  uiUpdateData.fuelData = {}
  for i, tank in ipairs(fuelData) do
    local tankData = {}
    tankData.energyType = tank.energyType
    tankData.tankIndex = i
    tankData.tankName = tank.name
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
  for i, tank in ipairs(fuelData) do
    local tankData = {}
    tankData.energyType = tank.energyType
    tankData.tankIndex = i
    tankData.tankName = tank.name
    tankData.currentEnergy = jouleToReadableUnit(tank.currentEnergy, tank.energyType)
    tankData.fueledEnergy = jouleToReadableUnit(fuelingData[i].fueledEnergy, tank.energyType)
    tankData.price = fuelingData[i].price
    tankData.fuelingActive = fuelingActive[i]
    uiUpdateData.fuelData[i] = tankData
  end
  uiUpdateData.flowRate = fuelFlowRate / maxFuelFlowRate

  guihooks.trigger('updateFuelData', uiUpdateData)
end

local function saveEnergyStorageData(data)
  fuelData = {}
  for _, tank in ipairs(data[1]) do
    -- only add the tank to the fuelData if it has a valid fuel type
    if factorMJToReadable[tank.energyType] then
      table.insert(fuelData, tank)
    end
  end
  showUI = true
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
  local veh = getPlayerVehicle(0)
  core_vehicleBridge.requestValue(veh, saveEnergyStorageData, 'energyStorage')
end

local function startAngularUI()
  guihooks.trigger('ChangeState', {state = 'refueling', params = {}})
end

local function requestRefuelingTransactionData()
  requestEnergyStorageData()
end

local function startTransaction(_gasStation)
  if not career_modules_inventory.getCurrentVehicle() then return end
  gasStation = _gasStation
  if freeroam_facilities_fuelPrice and freeroam_facilities_fuelPrice.setDisplayPrices then
    freeroam_facilities_fuelPrice.setDisplayPrices()
  end
  pushActionMap("Refueling")
  core_vehicleBridge.executeAction(getPlayerVehicle(0), 'setIgnitionLevel', 0)
  startAngularUI()
  extensions.hook("onRefuelingStartTransaction")
end

local function getFuelData()
  return fuelData
end

local function applyFuelData(data, veh)
  if showUI then
    sendUpdateDataToUI()
  end
  veh = veh or getPlayerVehicle(0)
  for index, tankData in ipairs(data or fuelData) do
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

local function getRelativeFuelLevel()
  local maxVolume = 0
  local currentVolume = 0
  for index, data in ipairs(fuelData) do
    if data.energyType == "gasoline" or data.energyType == "diesel" or data.energyType == "kerosine" then
      currentVolume = currentVolume + data.currentEnergy
      maxVolume = maxVolume + data.maxEnergy
    end
  end
  return currentVolume / maxVolume
end

local function updateFuelSoundParameters()
  local relativeFuelLevel = getRelativeFuelLevel()
  local sound = scenetree.findObjectById(gasSoundId)
  if sound then
    sound:setParameter("volume", relativeFuelLevel)
    sound:setParameter("pitch", fuelFlowRate / maxFuelFlowRate)
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
  extensions.hook("onRefuelingStopFueling", fuelData[index])
end

local function startFuelingTank(index)
  if career_modules_inventory.getCurrentVehicle() then
    local veh = getPlayerVehicle(0)
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

local function onChangeFlowRate(factor)
  if not gasStation then return end
  if not defaultEnergyType then
    initializeDefaultEnergyType()
    if not defaultEnergyType then
      return
    end
  end
  factor = clamp(factor, 0, 1)
  if factor <= 0 then
    stopFuelingType()
    fuelFlowRate = maxFuelFlowRate
    return
  end
  if not energyTypeFuelingActive[defaultEnergyType] then
    if getRelativeFuelLevel() < 1 then
      startFuelingType(defaultEnergyType)
    end
  end
  fuelFlowRate = maxFuelFlowRate * factor
end

local function getFuelingData()
  return fuelingData
end

local function endTransaction()
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
  fuelFlowRate = maxFuelFlowRate
  fuelDiscountData = {}
  activateSound(gasSoundId, false)
  activateSound(electricSoundId, false)
  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  else
    career_modules_inventory.updatePartConditions(nil, career_modules_inventory.getCurrentVehicle())
  end

  guihooks.trigger('ChangeState', {state ='play'})
  extensions.hook("onRefuelingEndTransaction")
end

local function payPrice()
  if overallPrice > 0 then
    Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  end
  stopFuelingType()

  if career_modules_inventory.getVehicles()[career_modules_inventory.getCurrentVehicle()].loanType == "work" then
    ui_message(string.format("Fuel paid for by the company"), 6, "refueling")
  else
    career_modules_playerAttributes.addAttributes({money=-overallPrice}, {tags={"fuel","buying"},label = "Refuelled at "..(translateLanguage(gasStation.facility.name, gasStation.facility.name, true))})
    gameplay_statistic.metricAdd("career/fuel/paidPrice.money", overallPrice)
  end

  endTransaction()
  extensions.hook("onPaidRefuelling", overallPrice)
end

local function uiButtonStartFueling(energyType)
  startFuelingType(energyType)
end

local function uiButtonStopFueling(energyType)
  stopFuelingType(energyType)
end

local function uiCancelTransaction()
  if fuelData then
    payPrice()
  end
end

local function isCurrentlyFueling()
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

local uiFuelDataDeltaCounter = 0
local function onUpdate(dtReal, dtSim)
  if showUI then
    local veh = getPlayerVehicle(0)
    if veh:getVelocity():length() > 2 then
      uiCancelTransaction()
    end
  end

  if fuelData then
    uiFuelDataDeltaCounter = uiFuelDataDeltaCounter + dtReal

    local applyAndSendToUI = false
    for index, data in ipairs(fuelData) do
      if fuelingActive[index] then
        data.currentEnergy = data.currentEnergy + dtSim * fuelFlowRate
        fuelingData[index].fueledEnergy = data.currentEnergy - startingFuelData[index].currentEnergy

        local price = getPricePerUnit(data.energyType) * jouleToReadableUnit(fuelingData[index].fueledEnergy, data.energyType)
        fuelingData[index].price = math.floor((price * 100) + 0.5) / 100
        if data.currentEnergy > data.maxEnergy then
          -- tank is full
          data.currentEnergy = data.maxEnergy
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
    imgui.SetNextWindowSize(imgui.ImVec2(200, 200), imgui.Cond_FirstUseEver)
    imgui.Begin("Fueling")

    for index, tankData in ipairs(fuelData) do
      if imgui.BeginChild1("Tank " .. index, imgui.ImVec2(0, 150), true) then
        imgui.Text("Tank " .. index)
        imgui.Text(string.format("Fuel Type: %s", tankData.energyType))
        local unit = readableUnit[tankData.energyType]
        imgui.Text(string.format("Energy: %.2f %s / %.2f %s", jouleToReadableUnit(tankData.currentEnergy, tankData.energyType), unit, jouleToReadableUnit(tankData.maxEnergy, tankData.energyType), unit))
        imgui.Text(string.format("Fueled Energy: %.2f %s", jouleToReadableUnit(fuelingData[index].fueledEnergy, tankData.energyType) or 0, unit))

        imgui.Text("Price " .. fuelingData[index].price or 0)
      end
      imgui.EndChild()
    end

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
    if overallPrice <= career_modules_playerAttributes.getAttributeValue("money") then
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
      ui_message("Your vehicle has been fully recharged", nil, "emergencyRefuel")
    elseif tank.currentEnergy <= tank.maxEnergy * 0.01 then
      tank.currentEnergy = tank.maxEnergy * 0.05
      ui_message("Your tank was close to empty, so it has been refueled a little bit. You should visit a fuel station", nil, "emergencyRefuel")
    end
  end
  applyFuelData(tanksData, veh)
end

local function minimumRefuelingCheck(vehId)
  vehId = vehId or career_modules_inventory.getCurrentVehicleId()
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

local function onCareerModulesActivated(alreadyInLevel)
  if alreadyInLevel then
    setupSounds()
  end
end

local function onClientStartMission(levelPath)
  setupSounds()
end

local function onClientEndMission(levelPath)
  gasSoundId = nil
  electricSoundId = nil
end

M.startTransaction = startTransaction
M.getFuelData = getFuelData
M.isCurrentlyFueling = isCurrentlyFueling
M.getFuelingData = getFuelingData
M.payPrice = payPrice
M.onChangeFlowRate = onChangeFlowRate

-- Called by UI
M.uiButtonStartFueling = uiButtonStartFueling
M.uiButtonStopFueling = uiButtonStopFueling
M.requestRefuelingTransactionData = requestRefuelingTransactionData
M.uiCancelTransaction = uiCancelTransaction
M.sendUpdateDataToUI = sendUpdateDataToUI

M.onUpdate = onUpdate
M.onCareerModulesActivated = onCareerModulesActivated
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.minimumRefuelingCheck = minimumRefuelingCheck

return M
