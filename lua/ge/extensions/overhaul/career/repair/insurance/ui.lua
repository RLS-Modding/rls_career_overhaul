-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Insurance computer menu, driver score reset, perks and small accessors.
-- Part of the Overhaul fork of stock lua/ge/extensions/career/modules/insurance/insurance.lua.
local partFactory = {}

-- inputs: state.
-- Bind sibling helpers after construction so each extension load keeps its own closures.
function partFactory.new(inputs)
  local insuranceState = inputs.state
  local M, TEST_DRIVE_ESTIMATE_INTERVAL, availableInsurances, closeMenu, defaultDriverScore,
    formatPerkIconData, getPlCoverageOptionValue, quickRepairExtraPrice,
    refreshTestDriveChargeEstimate, sendUIData, testDriveDamagePlayerShare, tetherRange

  local function onOverhaulVehicleSaveFinished()
    if insuranceState.closeMenuAfterSaving then
      closeMenu()
      insuranceState.closeMenuAfterSaving = nil
    end
  end

  -- open the insurances computer menu
  local function openMenu(_originComputerId)
    insuranceState.originComputerId = _originComputerId
    if insuranceState.originComputerId then
      if insuranceState.tether then insuranceState.tether.remove = true end
      insuranceState.tether = nil
      local computer = overhaul_world_facilities.getFacility("computer", insuranceState.originComputerId)
      if computer then
        local door = computer.doors and computer.doors[1]
        if door then
          insuranceState.tether = overhaul_career_maintenance_tether.startDoorTether(door, tetherRange, overhaul_career_career.closeAllMenus)
        end
        if not insuranceState.tether then
          local pos = overhaul_world_facilities.getAverageDoorPositionForFacility(computer)
          if pos then
            insuranceState.tether = overhaul_career_maintenance_tether.startSphereTether(pos, tetherRange, overhaul_career_career.closeAllMenus)
          end
        end
      end

      overhaul_career_ui_log.addLog(string.format("Opened insurances from computer %s", tostring(insuranceState.originComputerId)), "insurance")

      extensions.ui_router.navigate('overhaul.computer.insurances')
      extensions.hook("onOverhaulComputerInsurance")
    end
  end

  local function onMenuClosed()
    if insuranceState.tether then
      insuranceState.tether.remove = true
      insuranceState.tether = nil
    end
  end

  local function onExitInsurancesComputerScreen()
    insuranceState.insuranceMenuOpen = false
  end

  local function onOverhaulComputerAddFunctions(menuData, computerFunctions)
    if menuData.computerFacility.functions["insurances"] then
      local computerFunctionData = {
        id = "insurances",
        routeTarget = "overhaul.computer.insurances",
        label = _tr("ui.career.insurance.title"),
        callback = function() openMenu(menuData.computerFacility.id) end,
        order = 15
      }
      if not menuData.hasBoughtStarterVehicle then
        computerFunctionData.disabled = true
        computerFunctionData.reason = overhaul_career_garage_computer.reasons.hasBoughtStarterVehicle
      end
      computerFunctions.general[computerFunctionData.id] = computerFunctionData
    end
  end

  local function getDriverScoreResetCost()
    local currentScore = insuranceState.plDriverScore

    if currentScore >= defaultDriverScore then
      return 0
    end

    local distance = defaultDriverScore - currentScore
    local minCost = 500
    local maxCost = 20000

    local buyoutCost = minCost + math.abs(distance / defaultDriverScore) * (maxCost - minCost)

    return math.floor(buyoutCost)
  end

  local function resetDriverScore()
    local resetCost = getDriverScoreResetCost()
    if resetCost <= 0 then
      return false
    end

    local formattedPrice = {money = {amount = resetCost, canBeNegative = false}}
    if overhaul_career_economy_payment.canPay(formattedPrice) then
      local oldScore = insuranceState.plDriverScore
      overhaul_career_economy_payment.pay(formattedPrice, {category = "insurance", finance = {vehicleRelated = false}, label="Driver score reset"})
      insuranceState.plDriverScore = defaultDriverScore
      overhaul_career_repair_insuranceHistory.addToPlHistory({
        type = "driverScoreReset",
        title = "Driver score reset",
        effects = {
          {type = "money", label = "Money", changedBy = -resetCost, newValue = overhaul_career_economy_playerAttributes.getAttributeValue("money")},
          {type = "driverScore", label = "Driver score", changedBy = defaultDriverScore - oldScore, newValue = insuranceState.plDriverScore}
        }
      })
      overhaul_career_ui_log.addLog(string.format("Reset driver score from %d to %d for %.2f", oldScore, insuranceState.plDriverScore, resetCost), "insurance")

      sendUIData()
      overhaul_career_repair_playerAbstract.sendPlayerAbstractDataToUI()
      return true
    end
    return false
  end

  local function getInvVehRepairTime(vehInvId)
    return getPlCoverageOptionValue(vehInvId, "repairTime")
  end

  local function getPlayerInsurancesData()
    return insuranceState.plInsurancesData
  end

  local function getQuickRepairExtraPrice()
    return quickRepairExtraPrice
  end

  local function getVehInsuranceInfo(vehInvId)
    if not insuranceState.invVehs[vehInvId] then return end
    local insuranceId = insuranceState.invVehs[vehInvId].insuranceId or -1
    local insuranceInfo = availableInsurances[insuranceId]
    local isInsured = insuranceId > 0 and insuranceInfo ~= nil
    return {
      isInsured = isInsured,
      insuranceInfo = insuranceInfo,
      insuranceClass = insuranceState.invVehs[vehInvId].requiredInsuranceClass,
    }
  end

  local function expediteRepair(inventoryId, price)
    if overhaul_career_economy_payment.pay({money = {amount = price, canBeNegative = false}}, {category = "repair", finance = {vehicleId = inventoryId}, label="Expedited repair"}) then
      local vehInfo = overhaul_career_garage_inventory.getVehicles()[inventoryId]
      vehInfo.timeToAccess = nil
      vehInfo.delayReason = nil
      vehInfo.repairTimeTotal = nil
      overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
      overhaul_career_ui_log.addLog(string.format("Expedited repair of vehicle %s for %.2f", tostring(inventoryId), price), "insurance")
    end
  end

  local function saveNewInsuranceCoverageOptions(insuranceId, newCoverageOptions)
    if overhaul_career_economy_payment.canPay({money = {amount = availableInsurances[insuranceId].paperworkFees, canBeNegative = false}}) then
      overhaul_career_economy_payment.pay({money = {amount = availableInsurances[insuranceId].paperworkFees, canBeNegative = false}}, {category = "insurance", finance = {vehicleRelated = false}, label="Insurance coverage options changed"})
      gameplay_achievement.unlockAchievement("POLICY_REVIEW")

      -- check if roadsideAssistance was changed
      local oldRoadsideAssistance = insuranceState.plInsurancesData[insuranceId].coverageOptionsData.currentCoverageOptions["roadsideAssistance"]
      local newRoadsideAssistance = newCoverageOptions["roadsideAssistance"]

      insuranceState.plInsurancesData[insuranceId].coverageOptionsData.currentCoverageOptions = newCoverageOptions

      -- and if something was changed, top up roadside assistance
      if oldRoadsideAssistance ~= newRoadsideAssistance then
        M.topUpRoadsideAssistance(insuranceId)
      end

      overhaul_career_ui_log.addLog(string.format("Saved insurance-wide coverage options for %s, paperwork fee %.2f",
        M.getInsuranceName(insuranceId), availableInsurances[insuranceId].paperworkFees), "insurance")

      sendUIData()
    end
  end

  local function saveNewVehicleCoverageOptions(vehicleId, newCoverageOptions)
    if overhaul_career_economy_payment.canPay({money = {amount = availableInsurances[insuranceState.invVehs[vehicleId].insuranceId].paperworkFees, canBeNegative = false}}) then
      overhaul_career_economy_payment.pay({money = {amount = availableInsurances[insuranceState.invVehs[vehicleId].insuranceId].paperworkFees, canBeNegative = false}}, {category = "insurance", finance = {vehicleId = vehicleId}, label="Vehicle coverage options changed"})
      insuranceState.invVehs[vehicleId].insuranceData.coverageOptionsData.currentCoverageOptions = newCoverageOptions
      overhaul_career_ui_log.addLog(string.format("Saved coverage options for vehicle %s on insurance %s, paperwork fee %.2f",
        tostring(vehicleId), M.getInsuranceName(insuranceState.invVehs[vehicleId].insuranceId),
        availableInsurances[insuranceState.invVehs[vehicleId].insuranceId].paperworkFees), "insurance")
      sendUIData()
      gameplay_achievement.unlockAchievement("POLICY_REVIEW")
    end
  end

  local function topUpRoadsideAssistance(insuranceId)
    local roadsideAssistanceValueId = insuranceState.plInsurancesData[insuranceId].coverageOptionsData.currentCoverageOptions["roadsideAssistance"]
    local roadsideAssitanceCoverageAmount = availableInsurances[insuranceId].coverageOptions.roadsideAssistance.choices[roadsideAssistanceValueId].value
    insuranceState.plInsurancesData[insuranceId].roadsideAssistance = roadsideAssitanceCoverageAmount
  end

  local function isRoadSideAssistanceFree(invVehId)
    if not insuranceState.invVehs[invVehId] then return false end
    if not insuranceState.plInsurancesData[insuranceState.invVehs[invVehId].insuranceId] then return false end

    local value = insuranceState.plInsurancesData[insuranceState.invVehs[invVehId].insuranceId].roadsideAssistance
    return value > 0
  end

  local function useRoadsideAssistance(invVehId)
    if not insuranceState.invVehs[invVehId] then return end
    if not insuranceState.plInsurancesData[insuranceState.invVehs[invVehId].insuranceId] then return end

    insuranceState.plInsurancesData[insuranceState.invVehs[invVehId].insuranceId].roadsideAssistance = insuranceState.plInsurancesData[insuranceState.invVehs[invVehId].insuranceId].roadsideAssistance - 1

    overhaul_career_ui_log.addLog(string.format("Used roadside assistance on vehicle %s (insurance %s), %d uses left",
      tostring(invVehId), M.getInsuranceName(insuranceState.invVehs[invVehId].insuranceId),
      insuranceState.plInsurancesData[insuranceState.invVehs[invVehId].insuranceId].roadsideAssistance), "insurance")
  end

  local function getTestDriveClaimPrice()
    if insuranceState.testDriveVehId and not getObjectByID(insuranceState.testDriveVehId) then
      insuranceState.testDriveVehId = nil
      insuranceState.testDriveBaselineReady = false
      insuranceState.liveTestDriveCharge = 0
    end
    if insuranceState.testDriveVehId then
      if os.clock() - insuranceState.lastTestDriveEstimateRequest >= TEST_DRIVE_ESTIMATE_INTERVAL then
        refreshTestDriveChargeEstimate(insuranceState.testDriveVehId)
      end
      return insuranceState.liveTestDriveCharge
    end
    return insuranceState.lastTestDriveCharge
  end

  local function getTestDriveDamagePlayerShare()
    return testDriveDamagePlayerShare
  end

  local function getPerkValueByInsuranceId(insuranceId, perkId)
    if availableInsurances[insuranceId] and availableInsurances[insuranceId].perks and availableInsurances[insuranceId].perks[perkId] then
      return availableInsurances[insuranceId].perks[perkId].value
    end
    return nil
  end

  local function getPerkValueByInvVehId(invVehId, perkId)
    local invVehData = insuranceState.invVehs[invVehId]
    if not invVehData then return nil end
    return getPerkValueByInsuranceId(invVehData.insuranceId, perkId)
  end

  local function getDefaultInsuranceForClassId(insuranceClassId)
    local matchingInsurances = {}

    -- collect all insurances that match the class
    for _, insuranceInfo in pairs(availableInsurances) do
      if insuranceInfo.class == insuranceClassId then
        table.insert(matchingInsurances, insuranceInfo)
      end
    end

    -- sort by id
    table.sort(matchingInsurances, function(a, b)
      return a.id < b.id
    end)

    return matchingInsurances[1]
  end

  local function getInvVehFuelDiscountData(invVehId)
  local fuelDiscount = getPerkValueByInvVehId(invVehId, "fuelDiscount")

    local data = {
      hasFuelDiscount = fuelDiscount ~= nil,
      fuelDiscount = 0,
      perkData = nil,
    }

    if fuelDiscount then
      data.fuelDiscount = fuelDiscount
      data.insuranceName = availableInsurances[insuranceState.invVehs[invVehId].insuranceId].name
      local insuranceId = insuranceState.invVehs[invVehId].insuranceId
      local isSignaturePerk = availableInsurances[insuranceId].perks.fuelDiscount.isSignaturePerk or false
      data.perkData = formatPerkIconData(string.format("- %i%%", data.fuelDiscount * 100), string.format("Your %s insurance saves you %i%% on fuel and charging!", data.insuranceName, data.fuelDiscount * 100), nil, isSignaturePerk)
      end

    return data
  end

  local function getInsuranceDataById(insuranceId)
    return availableInsurances[insuranceId]
  end

  local chooseInsuranceRoutes = {
    purchase = "overhaul.computer.vehicleShopping.vehicles.vehiclePurchase.chooseInsurance",
    change = "overhaul.computer.insurances.chooseInsurance",
  }

  -- purchase params: { purchaseType, shopId, insuranceId? }; change params: { vehicleId }
  local function openChooseInsuranceScreen(mode, params)
    local routeName = chooseInsuranceRoutes[mode]
    if not routeName then
      log("E", "", "openChooseInsuranceScreen: unknown mode " .. tostring(mode))
      return { result = false, success = false, reason = "unknown_mode" }
    end
    return extensions.ui_router.navigate(routeName, params)
  end

  local function setDriverScore(score)
    insuranceState.plDriverScore = score
  end

  local function doesInsuranceExist(insuranceId)
    return availableInsurances[insuranceId] ~= nil
  end

  local function getInsuranceName(insuranceId)
    return availableInsurances[insuranceId] and availableInsurances[insuranceId].name or "No Insurance"
  end

  local function getAccidentForgivenessCount(insuranceId)
    return insuranceState.plInsurancesData[insuranceId] and insuranceState.plInsurancesData[insuranceId].accidentForgiveness or 0
  end

  return {
    doesInsuranceExist = doesInsuranceExist,
    expediteRepair = expediteRepair,
    getAccidentForgivenessCount = getAccidentForgivenessCount,
    getDefaultInsuranceForClassId = getDefaultInsuranceForClassId,
    getDriverScoreResetCost = getDriverScoreResetCost,
    getInsuranceDataById = getInsuranceDataById,
    getInsuranceName = getInsuranceName,
    getInvVehFuelDiscountData = getInvVehFuelDiscountData,
    getInvVehRepairTime = getInvVehRepairTime,
    getPerkValueByInsuranceId = getPerkValueByInsuranceId,
    getPerkValueByInvVehId = getPerkValueByInvVehId,
    getPlayerInsurancesData = getPlayerInsurancesData,
    getQuickRepairExtraPrice = getQuickRepairExtraPrice,
    getTestDriveClaimPrice = getTestDriveClaimPrice,
    getTestDriveDamagePlayerShare = getTestDriveDamagePlayerShare,
    getVehInsuranceInfo = getVehInsuranceInfo,
    isRoadSideAssistanceFree = isRoadSideAssistanceFree,
    onExitInsurancesComputerScreen = onExitInsurancesComputerScreen,
    onMenuClosed = onMenuClosed,
    onOverhaulComputerAddFunctions = onOverhaulComputerAddFunctions,
    onOverhaulVehicleSaveFinished = onOverhaulVehicleSaveFinished,
    openChooseInsuranceScreen = openChooseInsuranceScreen,
    openMenu = openMenu,
    resetDriverScore = resetDriverScore,
    saveNewInsuranceCoverageOptions = saveNewInsuranceCoverageOptions,
    saveNewVehicleCoverageOptions = saveNewVehicleCoverageOptions,
    setDriverScore = setDriverScore,
    topUpRoadsideAssistance = topUpRoadsideAssistance,
    useRoadsideAssistance = useRoadsideAssistance,
    bindInputs = function(inputs)
      M = inputs.M
      TEST_DRIVE_ESTIMATE_INTERVAL = inputs.TEST_DRIVE_ESTIMATE_INTERVAL
      availableInsurances = inputs.availableInsurances
      closeMenu = inputs.closeMenu
      defaultDriverScore = inputs.defaultDriverScore
      formatPerkIconData = inputs.formatPerkIconData
      getPlCoverageOptionValue = inputs.getPlCoverageOptionValue
      quickRepairExtraPrice = inputs.quickRepairExtraPrice
      refreshTestDriveChargeEstimate = inputs.refreshTestDriveChargeEstimate
      sendUIData = inputs.sendUIData
      testDriveDamagePlayerShare = inputs.testDriveDamagePlayerShare
      tetherRange = inputs.tetherRange
    end,
  }
end

return partFactory
