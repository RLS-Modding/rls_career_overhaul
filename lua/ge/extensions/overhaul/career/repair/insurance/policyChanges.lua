-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Policy changes: switching costs, insurance options and UI data, adding/removing vehicles, coverage changes.
-- Part of the Overhaul fork of stock lua/ge/extensions/career/modules/insurance/insurance.lua.
local partFactory = {}

-- inputs: state.
-- Bind sibling helpers after construction so each extension load keeps its own closures.
function partFactory.new(inputs)
  local insuranceState = inputs.state
  local M, availableClasses, availableInsurances, calculateAddVehiclePrice, calculateVehiclePremium,
    createNoInsuranceCard, defaultDriverScore, getApplicableInsuranceClass, getCoverageRefundPrice,
    getDriverScoreTierData, getEarlyTerminationPenalty, getInsuranceGroupDiscountTierData,
    getInsuranceSanitizedData, getInsurancesByClass, getInvVehDataById, getInvVehsUnderClass,
    getInvVehsUnderInsurance, getNetRefundPrice, getRenewsIn, getSanitizedInsuranceDataForPurchase,
    insuranceEditTime, inventoryVehNeedsRepair

  local function calculateInsuranceSwitchingCost(invVehId, newInsuranceId)
    local invVeh = getInvVehDataById(invVehId)
    if not invVeh then return 0 end
    return getNetRefundPrice(invVehId) - calculateAddVehiclePrice(newInsuranceId, invVeh.initialValue)
  end

  local function buildLeavingInsuranceInfo(invVehId)
    local invVeh = getInvVehDataById(invVehId)
    if not invVeh then return {} end
    local currentInsuranceId = invVeh.insuranceId
    local vehicleValue = invVeh.initialValue

    local data = {
      currentInsuranceName = availableInsurances[currentInsuranceId] and availableInsurances[currentInsuranceId].name or "No Insurance",
      vehicleCount = #getInvVehsUnderInsurance(currentInsuranceId),
      newVehicleCount = #getInvVehsUnderInsurance(currentInsuranceId) - 1,
      discountTierData = getInsuranceGroupDiscountTierData(currentInsuranceId),
      newDiscountTierData = getInsuranceGroupDiscountTierData(currentInsuranceId, nil, vehicleValue),
      coverageRefundPrice = getCoverageRefundPrice(invVehId),
      earlyTerminationPenalty = getEarlyTerminationPenalty(invVehId),
      netRefundPrice = getNetRefundPrice(invVehId),
      renewsIn = getRenewsIn(currentInsuranceId),
    }

    return data
  end

  local function getVehiclesInsuredCount()
    local count = 0
    for _, invVehData in pairs(insuranceState.invVehs) do
      local insuranceId = invVehData.insuranceId or -1
      if insuranceId > 0 then
        count = count + 1
      end
    end
    return count
  end

  local function getPlayerAbstractData()
    local data = {
      driverScore = insuranceState.plDriverScore,
      totalDistanceDriven = insuranceState.totalDrivenDistance,
      insuredDistanceDriven = insuranceState.insuredDrivenDistance or 0,
      uninsuredDistanceDriven = math.max(0, (insuranceState.totalDrivenDistance or 0) - (insuranceState.insuredDrivenDistance or 0)),
      driverScoreTier = getDriverScoreTierData(insuranceState.plDriverScore),
      repairHistory = {
        insuranceRepairs = overhaul_career_repair_insuranceHistory.getInsuranceClaimsCount(),
        privateRepairs = overhaul_career_repair_insuranceHistory.getNonInsuranceRepairsCount(),
      },
      driverScoreReset = {
        resetTo = defaultDriverScore,
        resetCost = M.getDriverScoreResetCost(),
      },
      financialSummary = {
        vehiclesInsuredCount = getVehiclesInsuredCount(),
        totalPremiumPaid = overhaul_career_repair_insuranceHistory.getTotalPremiumPaid(),
        totalDeductiblePaid = overhaul_career_repair_insuranceHistory.getTotalInsuranceRepairDeductiblesPaid(),
        totalPrivateRepairsPaid = overhaul_career_repair_insuranceHistory.getTotalPrivateRepairsPaid(),
        damageCoveredByInsurance = overhaul_career_repair_insuranceHistory.getDamageCostCoveredByInsurance(),
        totalPaid = 0,
      }
    }

    data.financialSummary.totalPaid = data.financialSummary.totalPremiumPaid + data.financialSummary.totalDeductiblePaid + data.financialSummary.totalPrivateRepairsPaid

    return data
  end

  local function buildInsuranceOptionsData(context)
    local data = {
      applicableInsurancesData = {},
      driverScoreData = {
        score = insuranceState.plDriverScore,
        tier = getDriverScoreTierData(insuranceState.plDriverScore),
      },
      vehicleInfo = deepcopy(context.vehicleInfo),
    }

    if context.type == "purchase" then
      local defaultInsuranceId = context.defaultInsuranceId or -1
      data.defaultInsuranceId = defaultInsuranceId
      data.insuranceClassId = context.insuranceClassId
      data.purchaseData = {
        vehShopId = context.vehShopId,
        purchaseType = context.purchaseType,
        defaultInsuranceId = defaultInsuranceId,
        insuranceClassId = context.insuranceClassId,
        vehicleInfo = deepcopy(context.vehicleInfo),
      }
    elseif context.type == "change" then
      data.defaultInsuranceId = insuranceState.invVehs[context.invVehId].insuranceId
      data.currentInsuranceId = insuranceState.invVehs[context.invVehId].insuranceId
    end


    -- always add "No insurance" option
    local noInsuranceCard = createNoInsuranceCard()
    if context.type == "change" then
      noInsuranceCard.leavingInsuranceInfo = buildLeavingInsuranceInfo(context.invVehId)
    end
    table.insert(data.applicableInsurancesData, noInsuranceCard)

    -- build insurance options
    local applicableInsurances = getInsurancesByClass(context.insuranceClassId)
    for _, insuranceInfo in pairs(applicableInsurances) do
      local sanitizedData

      -- only add leaving insurance info if we're in the "change" context
      sanitizedData = getSanitizedInsuranceDataForPurchase(insuranceInfo.id, context.vehicleInfo)
      if context.type == "change" then
        sanitizedData.leavingInsuranceInfo = buildLeavingInsuranceInfo(context.invVehId)
        sanitizedData.netSwitchingCost = calculateInsuranceSwitchingCost(context.invVehId, insuranceInfo.id)
        sanitizedData.amountDue = sanitizedData.netSwitchingCost * -1
        if data.currentInsuranceId == insuranceInfo.id then
          sanitizedData.amountDue = 0
        end
        sanitizedData.canPay = overhaul_career_economy_payment.canPay({money = {amount = sanitizedData.amountDue, canBeNegative = false}})
      end

      table.insert(data.applicableInsurancesData, sanitizedData)
    end

    -- sort by ID
    table.sort(data.applicableInsurancesData, function(a, b)
      return a.id < b.id
    end)

    return data
  end

  local function sendChangeInsuranceDataToTheUI(invVehId)
    local vehInfo = overhaul_career_garage_inventory.getVehicles()[invVehId]
    local invVeh = insuranceState.invVehs[invVehId]
    local vehicleInfo = {
      Name = (invVeh and invVeh.name) or (vehInfo and vehInfo.niceName),
      Value = invVeh and invVeh.initialValue,
      thumbnail = (overhaul_career_garage_inventory.getVehicleThumbnail(invVehId) or "") .. "?" .. ((vehInfo and vehInfo.dirtyDate) or ""),
      invVehId = invVehId,
    }
    if not invVeh or not invVeh.requiredInsuranceClass or not invVeh.requiredInsuranceClass.id then
      log("E", "insurance", "sendChangeInsuranceDataToTheUI: missing requiredInsuranceClass for " .. tostring(invVehId))
      local currentInsuranceId = (invVeh and invVeh.insuranceId) or -1
      local noInsuranceCard = createNoInsuranceCard()
      if invVeh then
        noInsuranceCard.leavingInsuranceInfo = buildLeavingInsuranceInfo(invVehId)
      end
      guihooks.trigger('chooseInsuranceData', {
        applicableInsurancesData = { noInsuranceCard },
        driverScoreData = {
          score = insuranceState.plDriverScore,
          tier = getDriverScoreTierData(insuranceState.plDriverScore),
        },
        vehicleInfo = vehicleInfo,
        defaultInsuranceId = currentInsuranceId,
        currentInsuranceId = currentInsuranceId,
      })
      return
    end
    local data = buildInsuranceOptionsData({
      type = "change",
      insuranceClassId = invVeh.requiredInsuranceClass.id,
      invVehId = invVehId,
      vehicleInfo = vehicleInfo,
    })
    guihooks.trigger('chooseInsuranceData', data)
  end

  local function sendChooseInsuranceDataToTheUI(purchaseType, vehShopId, defaultInsuranceId)
    local vehicleInfo = overhaul_career_market_vehicleShopping.getVehicleInfoByShopId(vehShopId)
    local data = buildInsuranceOptionsData({
      type = "purchase",
      insuranceClassId = vehicleInfo.insuranceClass.id,
      vehicleInfo = vehicleInfo,
      defaultInsuranceId = defaultInsuranceId,
      purchaseType = purchaseType,
      vehShopId = vehShopId,
    })
    guihooks.trigger('chooseInsuranceData', data)
  end

  local function sendUIData()
    insuranceState.insuranceMenuOpen = true


    local uninsuredVehs = getInvVehsUnderInsurance(-1)

    local data = {
      invVehsInsurancesData = {},
      plClassesData = {},
      plHistory = overhaul_career_repair_insuranceHistory.buildPlHistory(),
      driverScoreData = {
        score = insuranceState.plDriverScore,
        tier = getDriverScoreTierData(insuranceState.plDriverScore),
      },
      uninsuredVehsData = {
        title = "Uninsured",
        description = "View vehicles with no insurance coverage",
        carsUninsuredCount = #uninsuredVehs,
        carsUninsured = uninsuredVehs,
      },
      careerMoney = overhaul_career_economy_playerAttributes.getAttributeValue("money"),
      careerVouchers = overhaul_career_economy_playerAttributes.getAttributeValue("vouchers"),
    }

    -- format the data to make it easier to use in the UI
    for invVehId, invVehData in pairs(insuranceState.invVehs) do
      local invVehTileData = overhaul_career_garage_inventory.getVehicleUiData(invVehId)

      if invVehTileData then
        invVehTileData.insuranceName = availableInsurances[invVehData.insuranceId] and availableInsurances[invVehData.insuranceId].name or "None"
        invVehTileData.individualRenewalPrice = calculateVehiclePremium(invVehId).cost
        data.invVehsInsurancesData[invVehId] = invVehTileData
      end
    end

    for classId, classData in pairs(availableClasses) do
      local carsInsured = #getInvVehsUnderClass(classId)
      data.plClassesData[classId] = {
        name = classData.name,
        description = classData.description,
        icon = classData.icon,
        carsInsured = carsInsured,
        priority = classData.applicableConditions.priority,
        insurances = {},
      }
      for _, insuranceInfo in pairs(getInsurancesByClass(classId)) do
        table.insert(data.plClassesData[classId].insurances, getInsuranceSanitizedData(insuranceInfo.id))
      end
    end

    guihooks.trigger('insurancesData', data)
  end

  local function clearInvVehInsuranceEntry(invVehId)
    if invVehId == nil then return end
    insuranceState.invVehs[invVehId] = nil
    if type(invVehId) == "number" then
      insuranceState.invVehs[tostring(invVehId)] = nil
    elseif type(invVehId) == "string" then
      local asNumber = tonumber(invVehId)
      if asNumber ~= nil then insuranceState.invVehs[asNumber] = nil end
    end
  end

  local function isJobOrLoanInventoryVehicle(invVehData)
    if not invVehData then return false end
    if invVehData.owned == false then return true end
    if invVehData.loanType then return true end
    return false
  end

  -- remove the vehicle from the insuranced vehicles json files
  local function onVehicleRemovedFromInventory(invVehId)
    local hadEntry = getInvVehDataById(invVehId) ~= nil
    clearInvVehInsuranceEntry(invVehId)
    overhaul_career_ui_log.addLog(string.format("Vehicle %s removed from inventory, insurance entry %s", tostring(invVehId), hadEntry and "dropped" or "was already absent"), "insurance")
  end

  -- Pure setter: coverage defaults + loyalty. No payment, history, or UI refresh.
  local function applyInvVehInsurance(invVehId, newInsuranceId)
    local invVeh = insuranceState.invVehs[invVehId]
    if not invVeh then return end

    local oldInsuranceId = invVeh.insuranceId
    if type(newInsuranceId) ~= "number" then newInsuranceId = tonumber(newInsuranceId) or -1 end
    if newInsuranceId ~= math.floor(newInsuranceId) then newInsuranceId = -1 end

    if newInsuranceId > 0 then
      local insuranceInfo = availableInsurances[newInsuranceId]
      if not insuranceInfo then
        newInsuranceId = -1
      else
        for coverageOptionName, coverageOptionValue in pairs(insuranceInfo.coverageOptions) do
          if not insuranceState.availableCoverageOptions[coverageOptionName].isInsuranceWide then
            invVeh.insuranceData.coverageOptionsData.currentCoverageOptions[coverageOptionName] = coverageOptionValue.baseValueId
          end
        end

        if #getInvVehsUnderInsurance(newInsuranceId) == 0 then
          for coverageOptionName, coverageOptionValue in pairs(insuranceInfo.coverageOptions) do
            if insuranceState.availableCoverageOptions[coverageOptionName].isInsuranceWide then
              insuranceState.plInsurancesData[newInsuranceId].coverageOptionsData.currentCoverageOptions[coverageOptionName] = coverageOptionValue.baseValueId
            end
          end
        end
      end
    end

    invVeh.insuranceId = newInsuranceId

    if oldInsuranceId and oldInsuranceId > 0 and insuranceState.plInsurancesData[oldInsuranceId] and #getInvVehsUnderInsurance(oldInsuranceId) == 0 then
      insuranceState.plInsurancesData[oldInsuranceId].loyalty = 0
    end
  end

  local function logInsuranceChange(invVehId, oldInsuranceId, newInsuranceId, insuranceChangeFees)
    overhaul_career_ui_log.addLog(string.format("Changed insurance of vehicle %s from %s to %s, fee %.2f",
      tostring(invVehId), M.getInsuranceName(oldInsuranceId), M.getInsuranceName(newInsuranceId), tonumber(insuranceChangeFees) or 0), "insurance")
    gameplay_achievement.unlockAchievement("POLICY_REVIEW")
  end

  -- newInsuranceId can be -1 to remove the insurance
  local function changeInvVehInsurance(invVehId, newInsuranceId, forFree)
    local invVeh = insuranceState.invVehs[invVehId]
    if not invVeh then return end

    -- Allow first attach while damaged (empty coverage); block switches after that.
    local coverageOpts = invVeh.insuranceData
      and invVeh.insuranceData.coverageOptionsData
      and invVeh.insuranceData.coverageOptionsData.currentCoverageOptions
    local hasVehicleCoverage = type(coverageOpts) == "table" and next(coverageOpts) ~= nil
    if inventoryVehNeedsRepair(invVehId) and hasVehicleCoverage then
      return
    end

    if type(newInsuranceId) ~= "number" then newInsuranceId = tonumber(newInsuranceId) or -1 end
    if newInsuranceId == invVeh.insuranceId then return end
    local insuranceChangeFees = forFree and 0 or calculateInsuranceSwitchingCost(invVehId, newInsuranceId)
    local insuranceName = (newInsuranceId > 0 and availableInsurances[newInsuranceId] and availableInsurances[newInsuranceId].name) or "None"

    local oldInsuranceId = invVeh.insuranceId

    if forFree or insuranceChangeFees == 0 then
      applyInvVehInsurance(invVehId, newInsuranceId)
      logInsuranceChange(invVehId, oldInsuranceId, newInsuranceId, insuranceChangeFees)
      M.sendUIData()
      return
    end

    local inventoryVehicle = overhaul_career_garage_inventory.getVehicle(invVehId)
    local niceName = inventoryVehicle and
      core_locales.translateWithOrWithoutContext(inventoryVehicle.niceName) or
      "Vehicle"
    local label = string.format("Insurance of '%s' changed to '%s'", niceName, insuranceName)
    if insuranceChangeFees > 0 then
      applyInvVehInsurance(invVehId, newInsuranceId)
      logInsuranceChange(invVehId, oldInsuranceId, newInsuranceId, insuranceChangeFees)
      overhaul_career_economy_playerAttributes.addAttributes({money = insuranceChangeFees}, {category = "insurance", finance = {vehicleId = invVehId}, label=label}, true)
      overhaul_career_repair_insuranceHistory.addToPlHistory({
        type = "insuranceChanged",
        title = label,
        effects = {{type = "money", label = "Money", changedBy = insuranceChangeFees, newValue = overhaul_career_economy_playerAttributes.getAttributeValue("money")}},
        concernedInsuranceName = insuranceName
      })
    else
      if overhaul_career_economy_payment.pay(
        {money = {amount = insuranceChangeFees * -1, canBeNegative = false}},
        {category = "insurance", finance = {vehicleId = invVehId}, label = label, reason = "insuranceChange"}
      ) then
        applyInvVehInsurance(invVehId, newInsuranceId)
        logInsuranceChange(invVehId, oldInsuranceId, newInsuranceId, insuranceChangeFees)
        overhaul_career_repair_insuranceHistory.addToPlHistory({
          type = "insuranceChanged",
          title = label,
          effects = {{type = "money", label = "Money", changedBy = -insuranceChangeFees, newValue = overhaul_career_economy_playerAttributes.getAttributeValue("money")}},
          concernedInsuranceName = insuranceName
        })
      end
    end
    M.sendUIData()
  end

  -- Register inventory vehicles with insurance. Job/loaner vehicles must never be insured or billed.
  local function onOverhaulVehicleAddedToInventory(data)
    if not data or data.inventoryId == nil then return end
    local inventoryId = data.inventoryId
    if type(inventoryId) == "string" then
      local asNumber = tonumber(inventoryId)
      if asNumber ~= nil then inventoryId = asNumber end
    end
    -- Contract / loaner temporary ids are non-numeric strings; never insure those.
    if type(inventoryId) ~= "number" then return end

    local invVehDataEarly = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    -- Car Go / car hauling / company loaners / rentals reuse numeric inventory slots.
    -- Never attach or charge insurance for those, and drop any stale invVehs row.
    if isJobOrLoanInventoryVehicle(invVehDataEarly) then
      clearInvVehInsuranceEntry(inventoryId)
      return
    end

    local vehicleInfo = data.vehicleInfo
    local aggregates = vehicleInfo and vehicleInfo.aggregates

    local conditionData = {
      vehValue = overhaul_career_market_valueCalculator.getInventoryVehicleValue(inventoryId),
      population = vehicleInfo and vehicleInfo.Population or nil,
      bodyStyle = vehicleInfo and (vehicleInfo.BodyStyle or (aggregates and aggregates["Body Style"])) or nil,
      jsonInsuranceClass = aggregates and aggregates["InsuranceClass"] or nil,
    }

    -- Prefer shopping vehicleInfo; otherwise derive commercial class from inventory config.
    if vehicleInfo and vehicleInfo["Commercial Class"] then
      conditionData.commercialClass = tonumber(string.match(vehicleInfo["Commercial Class"], "%d+"))
    elseif invVehDataEarly and invVehDataEarly.model and invVehDataEarly.config and invVehDataEarly.config.partConfigFilename then
      local _, configName = path.splitWithoutExt(invVehDataEarly.config.partConfigFilename)
      local baseConfig = core_vehicles.getConfig(invVehDataEarly.model, configName)
      if baseConfig and baseConfig["Commercial Class"] then
        conditionData.commercialClass = tonumber(string.match(baseConfig["Commercial Class"], "%d+"))
      end
      if not conditionData.population and baseConfig then
        conditionData.population = baseConfig.Population
      end
      if not conditionData.bodyStyle and baseConfig then
        conditionData.bodyStyle = baseConfig.BodyStyle or (baseConfig.aggregates and baseConfig.aggregates["Body Style"])
      end
      if not conditionData.jsonInsuranceClass and baseConfig and baseConfig.aggregates then
        conditionData.jsonInsuranceClass = baseConfig.aggregates["InsuranceClass"]
      end
    end

    -- Default uninsured. Only an explicit positive insuranceId attaches coverage.
    -- (Lua treats -1 as truthy, so coerce carefully.)
    local insuranceId = -1
    if data.purchaseData and data.purchaseData.insuranceId ~= nil then
      local requested = tonumber(data.purchaseData.insuranceId)
      if requested and requested > 0 and requested == math.floor(requested) and availableInsurances[requested] then
        insuranceId = requested
      else
        insuranceId = -1
      end
    end

    local invVehData = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    local name = data.vehicleInfo and data.vehicleInfo.Name
    name = core_locales.translateWithOrWithoutContext(name)
    if type(name) ~= "string" or name == "" then
      name = overhaul_career_garage_inventory.getVehicleNiceNameTranslated(inventoryId)
    end
    if type(name) ~= "string" or name == "" then
      name = (invVehData and invVehData.model) or "Vehicle"
    end
    local initialValue = data.vehicleInfo and data.vehicleInfo.Value
      or ((invVehData and invVehData.configBaseValue) and (invVehData.configBaseValue / 3))
      or 0

    -- Always replace any stale invVehs row for this id (recycled inventory slots).
    clearInvVehInsuranceEntry(inventoryId)
    insuranceState.invVehs[inventoryId] = {
      insuranceId = -1,
      name = name,
      id = inventoryId,
      initialValue = initialValue,
      requiredInsuranceClass = (function()
        local cls = getApplicableInsuranceClass(conditionData)
        if cls then return cls end
        cls = availableClasses.dailyDriver or availableClasses["dailyDriver"]
        if cls then return cls end
        for _, classInfo in pairs(availableClasses) do
          return classInfo
        end
        return nil
      end)(),
      insuranceData = {
        coverageOptionsData = {
          currentCoverageOptions = {},
          nextInsuranceEditTimer = 0,
        }
      }
    }
    -- Purchases that selected coverage pay the attach fee; uninsured registration is free.
    if insuranceId > 0 then
      changeInvVehInsurance(inventoryId, insuranceId)
    else
      applyInvVehInsurance(inventoryId, -1)
    end

    overhaul_career_ui_log.addLog(string.format("Registered vehicle %s with insurance %s (initial value %.2f, class %s, purchase data %s)",
      tostring(inventoryId), M.getInsuranceName(insuranceId), tonumber(initialValue) or 0,
      tostring(insuranceState.invVehs[inventoryId] and insuranceState.invVehs[inventoryId].requiredInsuranceClass and insuranceState.invVehs[inventoryId].requiredInsuranceClass.id),
      data.purchaseData and "present" or "absent"), "insurance")
  end

  -- Backstop for grant paths that add owned inventory vehicles but forget to fire
  -- onOverhaulVehicleAddedToInventory (off-road recovery keep, reward grants, hardcore starter).
  -- Purchases that already registered overwrite this via the purchase hook.
  local function onOverhaulVehicleAdded(inventoryId)
    if inventoryId == nil then return end
    if type(inventoryId) == "string" then
      local asNumber = tonumber(inventoryId)
      if asNumber == nil then return end
      inventoryId = asNumber
    end
    if type(inventoryId) ~= "number" then return end

    local invVehData = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if isJobOrLoanInventoryVehicle(invVehData) then
      clearInvVehInsuranceEntry(inventoryId)
      return
    end
    if not invVehData or invVehData.owned ~= true then return end
    if getInvVehDataById(inventoryId) then return end

    onOverhaulVehicleAddedToInventory({
      inventoryId = inventoryId,
      purchaseData = {insuranceId = -1},
    })
  end

  local function changeInvVehInsuranceCoverageOptions(invVehId, changedCoverageOptions)
    if not insuranceState.invVehs[invVehId] then return end
    if not insuranceState.plInsurancesData[insuranceState.invVehs[invVehId].insuranceId] then return end
    for coverageOptionName, coverageOptionValue in pairs(changedCoverageOptions) do
      local coverageOptionValueIndex = tableFindKey(availableInsurances[insuranceState.invVehs[invVehId].insuranceId].coverageOptions[coverageOptionName].changeability.changeParams.choices, coverageOptionValue)

      if insuranceState.availableCoverageOptions[coverageOptionName] and insuranceState.availableCoverageOptions[coverageOptionName].isInsuranceWide then
        insuranceState.plInsurancesData[insuranceState.invVehs[invVehId].insuranceId].coverageOptionsData.currentCoverageOptions[coverageOptionName] = coverageOptionValueIndex
      else
        insuranceState.invVehs[invVehId].insuranceData.coverageOptionsData.currentCoverageOptions[coverageOptionName] = coverageOptionValueIndex
      end
    end

    overhaul_career_repair_insuranceHistory.addToPlHistory({
      type = "insuranceCoverageChanged",
      title = "Insurance coverage options changed",
      effects = {{type = "insuranceCoverageChanged", label = "Insurance coverage changed", changedBy = -availableInsurances[insuranceState.invVehs[invVehId].insuranceId].paperworkFees, newValue = overhaul_career_economy_playerAttributes.getAttributeValue("money")}},
      concernedInsuranceName = availableInsurances[insuranceState.invVehs[invVehId].insuranceId].name
    })

    local label = string.format("Insurance coverage changed. Tier : %s", availableInsurances[insuranceState.invVehs[invVehId].insuranceId].name)
    overhaul_career_economy_payment.pay({money = { amount = availableInsurances[insuranceState.invVehs[invVehId].insuranceId].paperworkFees, canBeNegative = false}}, {category = "insurance", finance = {vehicleId = invVehId}, label=label})
    insuranceState.plInsurancesData[insuranceState.invVehs[invVehId].insuranceId].nextInsuranceEditTimer = insuranceEditTime

    overhaul_career_ui_log.addLog(string.format("Changed coverage options of vehicle %s on insurance %s, paperwork fee %.2f",
      tostring(invVehId), M.getInsuranceName(insuranceState.invVehs[invVehId].insuranceId),
      availableInsurances[insuranceState.invVehs[invVehId].insuranceId].paperworkFees), "insurance")

    M.sendUIData()
  end

  -- close the insurances computer menu
  local function closeMenu(_closeMenuAfterSaving)
    insuranceState.closeMenuAfterSaving = overhaul_career_career.isAutosaveEnabled() and _closeMenuAfterSaving

    if not insuranceState.closeMenuAfterSaving then
      if insuranceState.originComputerId then
        local computer = overhaul_world_facilities.getFacility("computer", insuranceState.originComputerId)
        overhaul_career_garage_computer.openMenu(computer)
      else
        overhaul_career_career.closeAllMenus()
      end
    end
  end

  return {
    changeInvVehInsurance = changeInvVehInsurance,
    changeInvVehInsuranceCoverageOptions = changeInvVehInsuranceCoverageOptions,
    closeMenu = closeMenu,
    getPlayerAbstractData = getPlayerAbstractData,
    onOverhaulVehicleAdded = onOverhaulVehicleAdded,
    onOverhaulVehicleAddedToInventory = onOverhaulVehicleAddedToInventory,
    onVehicleRemovedFromInventory = onVehicleRemovedFromInventory,
    sendChangeInsuranceDataToTheUI = sendChangeInsuranceDataToTheUI,
    sendChooseInsuranceDataToTheUI = sendChooseInsuranceDataToTheUI,
    sendUIData = sendUIData,
    bindInputs = function(inputs)
      M = inputs.M
      availableClasses = inputs.availableClasses
      availableInsurances = inputs.availableInsurances
      calculateAddVehiclePrice = inputs.calculateAddVehiclePrice
      calculateVehiclePremium = inputs.calculateVehiclePremium
      createNoInsuranceCard = inputs.createNoInsuranceCard
      defaultDriverScore = inputs.defaultDriverScore
      getApplicableInsuranceClass = inputs.getApplicableInsuranceClass
      getCoverageRefundPrice = inputs.getCoverageRefundPrice
      getDriverScoreTierData = inputs.getDriverScoreTierData
      getEarlyTerminationPenalty = inputs.getEarlyTerminationPenalty
      getInsuranceGroupDiscountTierData = inputs.getInsuranceGroupDiscountTierData
      getInsuranceSanitizedData = inputs.getInsuranceSanitizedData
      getInsurancesByClass = inputs.getInsurancesByClass
      getInvVehDataById = inputs.getInvVehDataById
      getInvVehsUnderClass = inputs.getInvVehsUnderClass
      getInvVehsUnderInsurance = inputs.getInvVehsUnderInsurance
      getNetRefundPrice = inputs.getNetRefundPrice
      getRenewsIn = inputs.getRenewsIn
      getSanitizedInsuranceDataForPurchase = inputs.getSanitizedInsuranceDataForPurchase
      insuranceEditTime = inputs.insuranceEditTime
      inventoryVehNeedsRepair = inputs.inventoryVehNeedsRepair
    end,
  }
end

return partFactory
