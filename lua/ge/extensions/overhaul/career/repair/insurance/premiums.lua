-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Distance, renewals, driver score and gestures (onUpdate); premiums, discounts and policy quotes.
-- Part of the Overhaul fork of stock lua/ge/extensions/career/modules/insurance/insurance.lua.
local partFactory = {}

-- inputs: state.
-- Bind sibling helpers after construction so each extension load keeps its own closures.
function partFactory.new(inputs)
  local insuranceState = inputs.state
  local HOUSEKEEPING_INTERVAL, M, availableClasses, availableInsurances, conditions,
    driverScoreDecreaseDistance, earlyTerminationPenalty, gestures, getDriverScoreTierData,
    getInvVehDataById, getPlCoverageOptionValue, groupDiscountTiers, insuranceRenewalDistance,
    inventoryVehNeedsRepair, lastPos, loadInsurancesData, maxAccidentForgiveness,
    maxLoyaltyPerCarAndRenewal, maximumDriverScore, minLoyaltyPerCarAndRenewal,
    safeDrivingScoreIncrease, saveInsurancesData, setActiveInsurance, vec3Zero

  local function updateDistanceDriven(dtReal)
    local vehId = be:getPlayerVehicleID(0)
    local invVehId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
    if not invVehId then return end

    local vehicleData = map.objects[vehId]
    if not vehicleData then return end

    if lastPos ~= vec3Zero then
      local dist = lastPos:distance(vehicleData.pos)
      if dist < 0.001 then return end
      if dist > 10 then
        lastPos:set(vehicleData.pos)
        return
      end
      if insuranceState.plInsurancesData[insuranceState.activeInsuranceId] then
        insuranceState.plInsurancesData[insuranceState.activeInsuranceId].metersDriven = insuranceState.plInsurancesData[insuranceState.activeInsuranceId].metersDriven + dist
        insuranceState.insuredDrivenDistance = (insuranceState.insuredDrivenDistance or 0) + dist
      end
      insuranceState.totalDrivenDistance = insuranceState.totalDrivenDistance + dist
    end

    lastPos:set(vehicleData.pos)
  end

  local function renewActiveInsurance(insuranceId)
    if not availableInsurances[insuranceId] then return end
    local renewalPrice = M.calculateInsurancePremium(insuranceId).totalPriceWithDriverScore
    local logBookLabel = string.format("Insurance '%s' renewed!", availableInsurances[insuranceId].name)
    overhaul_career_economy_payment.pay({money = { amount = renewalPrice, canBeNegative = true}}, {category = "insurance", finance = {vehicleRelated = false}, label=logBookLabel})
    local label = string.format("Insurance '%s' renewed! (-%0.2f$)", availableInsurances[insuranceId].name, renewalPrice)
    ui_message(label)

    -- check if the insurance has the accidentForgivenessAtRenewal perk
    local accidentForgivenessPerkValue = M.getPerkValueByInsuranceId(insuranceId, "accidentForgivenessAtRenewal")
    if accidentForgivenessPerkValue then
      insuranceState.plInsurancesData[insuranceId].accidentForgiveness = math.min(insuranceState.plInsurancesData[insuranceId].accidentForgiveness + accidentForgivenessPerkValue, maxAccidentForgiveness)
    end

    M.topUpRoadsideAssistance(insuranceId)

    insuranceState.plInsurancesData[insuranceId].lastRenewedAt = insuranceState.plInsurancesData[insuranceId].metersDriven
    overhaul_career_repair_insuranceHistory.addToPlHistory({
      type = "insuranceRenewed",
      title = "Insurance renewed",
      effects = {{type = "money", label = "Money", changedBy = -renewalPrice, newValue = overhaul_career_economy_playerAttributes.getAttributeValue("money")}},
      concernedInsuranceName = availableInsurances[insuranceState.activeInsuranceId].name
    })

    overhaul_career_ui_log.addLog(string.format("Renewed insurance %s for %.2f, accident forgiveness now %d",
      M.getInsuranceName(insuranceId), renewalPrice, insuranceState.plInsurancesData[insuranceId].accidentForgiveness), "insurance")
  end

  local function sanitizeCoverageOption(insuranceId, coverageOptionId, invVehId)
    if not availableInsurances[insuranceId] then return end

    local insuranceInfo = availableInsurances[insuranceId]
    local coverageOptionData = insuranceInfo.coverageOptions[coverageOptionId]

    local data = {}
    data = {
      key = coverageOptionId,
      name = coverageOptionData.niceName,
      choices = coverageOptionData.choices,
      choiceType = insuranceState.availableCoverageOptions[coverageOptionId].choiceType,
      perkText = coverageOptionData.perkText,
      displayOrder = insuranceState.availableCoverageOptions[coverageOptionId].displayOrder or 999,
    }

    if insuranceState.availableCoverageOptions[coverageOptionId].isInsuranceWide then
      data.currentValueId = insuranceState.plInsurancesData[insuranceId].coverageOptionsData.currentCoverageOptions[coverageOptionId]
    else
      data.currentValueId = insuranceState.invVehs[invVehId].insuranceData.coverageOptionsData.currentCoverageOptions[coverageOptionId]
    end

    return data
  end

  local function sanitizeCoverageOptions(insuranceId, currentCoverageOptions, invVehId)
    local coverageOptionsData = {}

    for coverageOptionId, coverageOptionValueId in pairs(currentCoverageOptions) do
      table.insert(coverageOptionsData, sanitizeCoverageOption(insuranceId, coverageOptionId, invVehId))
    end

    -- sort by displayOrder
    table.sort(coverageOptionsData, function(a, b)
      return a.displayOrder < b.displayOrder
    end)

    return coverageOptionsData
  end

  local function getInvVehsUnderInsurance(insuranceId)
    local invVehList = {}
    for invVehId, data in pairs(insuranceState.invVehs) do
      if data.insuranceId == insuranceId then
        local vehId = data.id or invVehId
        if type(vehId) == "string" then vehId = tonumber(vehId) or vehId end

        local vehInfo = overhaul_career_garage_inventory.getVehicles()[vehId]
        -- skip entries whose inventory vehicle is gone, like the invVehsInsurancesData loop in sendUIData
        if vehInfo then
          local vehData = deepcopy(data)
          local thumb = overhaul_career_garage_inventory.getVehicleThumbnail(vehId)
          if thumb then
            vehData.thumbnail = thumb .. "?" .. (vehInfo and vehInfo.dirtyDate or "")
          else
            vehData.thumbnail = ""
          end
          -- Ctrl+E / addVehicle used to persist locale tables as name; always send a string.
          local translatedName = overhaul_career_garage_inventory.getVehicleNiceNameTranslated(vehId)
          if type(translatedName) == "string" and translatedName ~= "" then
            vehData.name = translatedName
          elseif type(vehData.name) ~= "string" then
            vehData.name = (vehInfo and vehInfo.model) or "Vehicle"
          end
          vehData.needsRepair = inventoryVehNeedsRepair(vehId)
          table.insert(invVehList, vehData)
        end
      end
    end
    return invVehList
  end

  local function getInvVehsUnderClass(classId)
    local invVehList = {}
    for invVehId, data in pairs(insuranceState.invVehs) do
      if availableInsurances[data.insuranceId] and availableInsurances[data.insuranceId].class == classId then
        table.insert(invVehList, data)
      end
    end
    return invVehList
  end

  local function addLoyaltyPoints(insuranceId)
    local invVehCount = #getInvVehsUnderInsurance(insuranceId)
    local totalPoints = 0
    for i = 1, invVehCount do
      local loyaltyPoints = math.max(maxLoyaltyPerCarAndRenewal / i, minLoyaltyPerCarAndRenewal)
      totalPoints = totalPoints + loyaltyPoints
    end

    insuranceState.plInsurancesData[insuranceId].loyalty = insuranceState.plInsurancesData[insuranceId].loyalty + totalPoints
    insuranceState.plInsurancesData[insuranceId].loyalty = math.floor(math.min(insuranceState.plInsurancesData[insuranceId].loyalty, maxLoyaltyPerCarAndRenewal))
  end

  --make player pay for insurance renewal every X meters
  local function checkRenewInsurance()
    if insuranceState.plInsurancesData[insuranceState.activeInsuranceId].metersDriven - insuranceState.plInsurancesData[insuranceState.activeInsuranceId].lastRenewedAt >= insuranceRenewalDistance then
      renewActiveInsurance(insuranceState.activeInsuranceId)
      addLoyaltyPoints(insuranceState.activeInsuranceId)
    end
  end

  local function getActualRepairPrice(invVehId)
    return getPlCoverageOptionValue(invVehId, "deductible")
  end

  insuranceState.insuranceMenuOpen = false

  -- can't edit insurance coverage options instantly without delays, or players will cheat the system
  local function updateEditInsuranceCoverageOptionsTimer(dtReal)
    local sendDataToUI = false
    for _, invVehInsuranceData in pairs(insuranceState.invVehs) do
      local insuranceId = invVehInsuranceData and invVehInsuranceData.insuranceId
      if type(insuranceId) ~= "number" then insuranceId = tonumber(insuranceId) end
      if (insuranceId or -1) > 0 then
        local coverageOptionsData = invVehInsuranceData.insuranceData and invVehInsuranceData.insuranceData.coverageOptionsData
        local timer = coverageOptionsData and coverageOptionsData.nextInsuranceEditTimer
        if type(timer) == "number" and timer > 0 then
          coverageOptionsData.nextInsuranceEditTimer = math.max(0, timer - dtReal)
          sendDataToUI = true
        end
      end
    end

    if sendDataToUI and insuranceState.insuranceMenuOpen then
      M.sendUIData()
    end
  end

  -- gestures are commercial gestures, eg give the player a bonus after not having crashed for a while
  local function checkInsuranceGestures()
    local insuranceData = availableInsurances[insuranceState.activeInsuranceId]
    local plInsuranceData = insuranceState.plInsurancesData[insuranceState.activeInsuranceId]
    for gestureName, _ in pairs(insuranceData.gestures) do -- every gesture is based on driven distance for now
      local lastHappenedAt = plInsuranceData.gesturesData[gestureName].lastHappenedAt or 0

      if plInsuranceData.metersDriven - lastHappenedAt > insuranceData.gestures[gestureName].distance then
        if gestures[gestureName](plInsuranceData) then
          plInsuranceData.gesturesData[gestureName].lastHappenedAt = plInsuranceData.metersDriven
          overhaul_career_ui_log.addLog(string.format("Insurance %s granted gesture %s", M.getInsuranceName(insuranceState.activeInsuranceId), gestureName), "insurance")
        end
      end
    end
  end

  local function checkDriverScoreDecrease()
    local distSinceLastKm = insuranceState.insuredDrivenDistance - insuranceState.lastDriverScoreInsuredKmIncrease
    if distSinceLastKm >= driverScoreDecreaseDistance then
      insuranceState.lastDriverScoreKmIncrease = insuranceState.totalDrivenDistance
      insuranceState.lastDriverScoreInsuredKmIncrease = insuranceState.insuredDrivenDistance
      local oldScore = insuranceState.plDriverScore
      insuranceState.plDriverScore = math.min(insuranceState.plDriverScore + safeDrivingScoreIncrease, maximumDriverScore)
      if insuranceState.plDriverScore > oldScore then
        overhaul_career_repair_insuranceHistory.addToPlHistory({
          type = "driverScoreIncrease",
          title = "Safe driving",
          effects = {{type = "driverScore", label = "Driver score", changedBy = insuranceState.plDriverScore - oldScore, newValue = insuranceState.plDriverScore}},
          concernedInsuranceName = "Safe Driving"
        })
        overhaul_career_ui_log.addLog(string.format("Safe driving bonus: driver score %d -> %d", oldScore, insuranceState.plDriverScore), "insurance")
        ui_message(string.format("Safe driving: Driver score increased by %d to %d", safeDrivingScoreIncrease, insuranceState.plDriverScore))
      end
    end
  end

  local function onUpdate(dtReal, dtSim, dtRaw)
    local elapsedReal = math.max(tonumber(dtReal) or 0, 0)
    insuranceState.housekeepingAccumulator = insuranceState.housekeepingAccumulator + elapsedReal
    local runHousekeeping = insuranceState.housekeepingAccumulator >= HOUSEKEEPING_INTERVAL
    local housekeepingElapsed = runHousekeeping and insuranceState.housekeepingAccumulator or 0
    if runHousekeeping then
      insuranceState.housekeepingAccumulator = 0
    end

    if not gameplay_walk.isWalking() then
      -- Position sampling remains frame-accurate; only threshold scans are periodic.
      updateDistanceDriven(elapsedReal)
      if runHousekeeping and insuranceState.activeInsuranceId and insuranceState.activeInsuranceId > 0 then
        checkRenewInsurance()
        checkInsuranceGestures()
        checkDriverScoreDecrease()
      end
    end
    if runHousekeeping then
      updateEditInsuranceCoverageOptionsTimer(housekeepingElapsed)
    end
  end

  local function getInsurancesByClass(class)
    local insurances = {}
    for _, insuranceInfo in pairs(availableInsurances) do
      if insuranceInfo.class == class then
        table.insert(insurances, insuranceInfo)
      end
    end
    return insurances
  end

  local function getApplicableInsuranceClass(conditionData)

    if conditionData.jsonInsuranceClass then
      for className, value in pairs(conditionData.jsonInsuranceClass) do
        if value == true then
          return availableClasses[className]
        end
      end
    end

    -- for now still keeping the old logic just in case
    local applicableClasses = nil

    for _, classInfo in pairs(availableClasses) do
      if classInfo.applicableConditions then
        for condition, values in pairs(classInfo.applicableConditions.conditions) do -- that's an or condition
          if conditions[condition](conditionData, values) then
            if not applicableClasses then
              applicableClasses = {}
            end
            table.insert(applicableClasses, classInfo)
            break
          end
        end
      end
    end

    if applicableClasses then
      if #applicableClasses > 1 then
        table.sort(applicableClasses, function(a, b) return a.applicableConditions.priority > b.applicableConditions.priority end)
      end
      return applicableClasses[1]
    end

    return nil --should never reach here
  end

  local function getInsuranceClassFromVehicleShoppingData(data)
    local conditionData = {
      vehValue = data.Value,
      population = data.Population,
      bodyStyle = (data.BodyStyle and data.BodyStyle) or data.aggregates["Body Style"],
      jsonInsuranceClass = data.aggregates["InsuranceClass"],
    }
    if data["Commercial Class"] then
      conditionData.commercialClass = tonumber(string.match(data["Commercial Class"], "%d+"))
    end
    return getApplicableInsuranceClass(conditionData)
  end

  local function onVehicleSwitched()
    setActiveInsurance()
  end

  local function onOverhaulActive(active)
    if not active then return end
    loadInsurancesData()
  end

  local function onOverhaulSaveCurrentProfile(currentSavePath)
    saveInsurancesData(currentSavePath)
  end

  local function formatPerkIconData(smallText, tooltipText, discount, isSignaturePerk)
    return {
      smallText = smallText,
      tooltipText = tooltipText,
      discount = discount,
      isSignaturePerk = isSignaturePerk,
    }
  end

  local function getTotalInsuranceVehsValue(insuranceId)
    -- computer total vehicles value under the insurance
    local totalValue = 0
    for _, invVehData in pairs(getInvVehsUnderInsurance(insuranceId)) do
      if invVehData.initialValue then
        totalValue = totalValue + invVehData.initialValue
      end
    end
    return totalValue
  end

  local function getInsuranceGroupDiscountTierData(insuranceId, optionalExtraValue, optionalRemovedValue)
    if #getInvVehsUnderInsurance(insuranceId) + ((optionalExtraValue and 1) or 0) - ((optionalRemovedValue and 1) or 0) <= 1 then
      return {
        id = 0,
        discount = 0
      }
    end

    local totalValue = getTotalInsuranceVehsValue(insuranceId)
    if optionalExtraValue then
      totalValue = totalValue + optionalExtraValue
    end
    if optionalRemovedValue then
      totalValue = totalValue - optionalRemovedValue
    end

    -- find the tier that the total value falls into
    for _, tier in pairs(groupDiscountTiers) do
      if tier.max then
        if totalValue >= tier.min and totalValue <= tier.max then
          return tier
        end
      else
        if totalValue >= tier.min then
          return tier
        end
      end
    end
    return {
      id = 0,
      discount = 0
    }
  end

  -- either invVehId or nonInvVehInfo must be provided
  local function calculateVehiclePremium(invVehId, nonInvVehInfo, potentialCoverageOptions)
    local insuranceId, vehValue, insuranceClass
    local totalDiscount = 1

    local data = {
      cost = 0,
      costWithoutGroupDiscount = 0,
    }

    if nonInvVehInfo and next(nonInvVehInfo) then
      -- Potential vehicle: use insurance defaults
      insuranceId = nonInvVehInfo.insuranceId or -1

      if insuranceId == -1 then
        return data
      end

      local insuranceInfo = availableInsurances[insuranceId]
      if not insuranceInfo then return data end

      vehValue = nonInvVehInfo.vehValue
      insuranceClass = insuranceInfo.class
      if not vehValue or not insuranceClass or not availableClasses[insuranceClass] then return data end

      for coverageOptionId, coverageOptionData in pairs(potentialCoverageOptions or insuranceInfo.coverageOptions) do
        if insuranceState.availableCoverageOptions[coverageOptionId] and not insuranceState.availableCoverageOptions[coverageOptionId].isInsuranceWide then
          if coverageOptionData and coverageOptionData.choices and coverageOptionData.baseValueId and coverageOptionData.choices[coverageOptionData.baseValueId] then
            totalDiscount = totalDiscount * coverageOptionData.choices[coverageOptionData.baseValueId].premiumInfluence
          end
        end
      end
    else
      local invVeh = getInvVehDataById(invVehId)
      if not invVeh then return data end

      insuranceId = invVeh.insuranceId or -1

      if insuranceId == -1 then
        return data
      end

      vehValue = invVeh.initialValue
      insuranceClass = invVeh.requiredInsuranceClass and invVeh.requiredInsuranceClass.id
      if not vehValue or not insuranceClass or not availableClasses[insuranceClass] then return data end

      -- Insured vehicle: use current coverage options
      local insuranceInfo = availableInsurances[insuranceId]
      if not insuranceInfo then return data end
      local currentCoverage = potentialCoverageOptions
        or (invVeh.insuranceData and invVeh.insuranceData.coverageOptionsData and invVeh.insuranceData.coverageOptionsData.currentCoverageOptions)
        or {}
      for coverageOptionId, coverageOptionValueId in pairs(currentCoverage) do
        local cov = insuranceInfo.coverageOptions and insuranceInfo.coverageOptions[coverageOptionId]
        if cov and cov.choices and cov.choices[coverageOptionValueId] then
          totalDiscount = totalDiscount * cov.choices[coverageOptionValueId].premiumInfluence
        end
      end
    end

    local groupDiscount = 1 - getInsuranceGroupDiscountTierData(insuranceId).discount
    local baseRate = vehValue * availableClasses[insuranceClass].coverageRate

    data.cost = baseRate * totalDiscount * groupDiscount
    data.costWithoutGroupDiscount = baseRate * totalDiscount
    return data
  end

  -- potentialCoverageOptions is used to simulate the premium. That's so that the player can test different coverage options without actually changing the insurance coverage
  local function calculateInsurancePremium(insuranceId, potentialCoverageOptions, potentialVehiclesCoverageOptions, potentialNewVehValue)
    local details = {
      items = {
        vehsCoverage = {
          price = 0,
          priceWithoutGroupDiscount = 0,
          name = "Multi-vehicle discount",
        },
      },
      totalPrice = 0,
      totalPriceWithDriverScore = 0,
      groupDiscountSavings = 0,
    }

    if not availableInsurances[insuranceId] then
      return details
    end

    if potentialCoverageOptions and not next(potentialCoverageOptions) then -- UI always send an empty table
      potentialCoverageOptions = nil
    end
    if potentialVehiclesCoverageOptions and not next(potentialVehiclesCoverageOptions) then -- UI always send an empty table
      potentialVehiclesCoverageOptions = nil
    end

    local hasVehicles = false

    for _, invVehData in pairs(getInvVehsUnderInsurance(insuranceId)) do
      hasVehicles = true
      local vehCoverageOptions = potentialVehiclesCoverageOptions and potentialVehiclesCoverageOptions[tostring(invVehData.id)]
      local vehPremium = calculateVehiclePremium(invVehData.id, nil, vehCoverageOptions)
      details.items.vehsCoverage.price = details.items.vehsCoverage.price + vehPremium.cost
      details.items.vehsCoverage.priceWithoutGroupDiscount = details.items.vehsCoverage.priceWithoutGroupDiscount + vehPremium.costWithoutGroupDiscount
    end
    if potentialNewVehValue then
      hasVehicles = true
      local vehPremium = calculateVehiclePremium(nil, {vehValue = potentialNewVehValue, insuranceId = insuranceId})
      details.items.vehsCoverage.price = details.items.vehsCoverage.price + vehPremium.cost
      details.items.vehsCoverage.priceWithoutGroupDiscount = details.items.vehsCoverage.priceWithoutGroupDiscount + vehPremium.costWithoutGroupDiscount
    end

    -- calculate group discount savings
    details.groupDiscountSavings = details.items.vehsCoverage.priceWithoutGroupDiscount - details.items.vehsCoverage.price

    if hasVehicles then
      local plCoverage = (((insuranceState.plInsurancesData or {})[insuranceId] or {}).coverageOptionsData or {}).currentCoverageOptions or {}
      for coverageOptionName, coverageOptionValueId in pairs(potentialCoverageOptions or plCoverage) do
        local coverageOption = availableInsurances[insuranceId].coverageOptions[coverageOptionName]
        if insuranceState.availableCoverageOptions[coverageOptionName].isInsuranceWide then --only add insurance wide coverage options
          details.items[coverageOptionName] = {
            price = coverageOption.choices[coverageOptionValueId].premiumInfluence,
            name = coverageOption.niceName,
          }
        end
      end
    end

    for detailName, detailPrice in pairs(details.items) do
      details.totalPrice = details.totalPrice + detailPrice.price
    end
    local insuranceMult = overhaul_career_economy_globalEconomy.getInsurancePriceMultiplier() or 1.0
    details.totalPrice = math.floor(details.totalPrice * insuranceMult + 0.5)
    details.totalPriceWithDriverScore = math.floor(details.totalPrice * getDriverScoreTierData(insuranceState.plDriverScore).multiplier + 0.5)
    return details
  end

  local function getRenewsIn(insuranceId)
    if insuranceId == -1 or insuranceState.plInsurancesData[insuranceId] == nil then
      return 0
    end
    local metersRemaining = insuranceRenewalDistance - (insuranceState.plInsurancesData[insuranceId].metersDriven - insuranceState.plInsurancesData[insuranceId].lastRenewedAt)
    return math.ceil(metersRemaining / 1000)
  end

  local function calculateAddOnVehicleProRatedPrice(insuranceId, vehValue)
    local fullPrice = calculateVehiclePremium(nil, {vehValue = vehValue, insuranceId = insuranceId}).cost

    local metersRemaining = getRenewsIn(insuranceId) * 1000
    local proRatedRatio = metersRemaining / insuranceRenewalDistance
    local price = fullPrice * proRatedRatio
    local insuranceMult = overhaul_career_economy_globalEconomy.getInsurancePriceMultiplier() or 1.0
    local premium = math.floor(price * insuranceMult + 0.5)
    return math.floor(premium * getDriverScoreTierData(insuranceState.plDriverScore).multiplier + 0.5)
  end

  local function calculateAddVehiclePrice(insuranceId, vehValue)
    if #getInvVehsUnderInsurance(insuranceId) == 0 then
      return calculateInsurancePremium(insuranceId, nil, nil, vehValue).totalPriceWithDriverScore
    else
      return calculateAddOnVehicleProRatedPrice(insuranceId, vehValue)
    end
  end

  local function getTotalInsuranceVehsValue(insuranceId)
    local totalValue = 0
    for _, invVehData in pairs(getInvVehsUnderInsurance(insuranceId)) do
      if invVehData.initialValue then
        totalValue = totalValue + invVehData.initialValue
      end
    end
    return totalValue
  end

  local function getInsuranceSanitizedData(insuranceId)
    local insuranceInfo = availableInsurances[insuranceId]
    if not insuranceInfo then return end
    local sanitizedData = {}
    local reduceDeductiblePerk = M.getPerkValueByInsuranceId(insuranceInfo.id, "reduceDeductible")
    local carsInsured = getInvVehsUnderInsurance(insuranceInfo.id)
    local currentTierData = getInsuranceGroupDiscountTierData(insuranceInfo.id)
    local plCoverageOptions = (((insuranceState.plInsurancesData or {})[insuranceInfo.id] or {}).coverageOptionsData or {}).currentCoverageOptions or {}

    for _, invVehData in pairs(carsInsured) do
      invVehData.insuranceData.currentPremiumPrice = calculateVehiclePremium(invVehData.id).cost
      invVehData.insuranceData.coverageOptionsData.currentCoverageOptionsSanitized = sanitizeCoverageOptions(insuranceId, invVehData.insuranceData.coverageOptionsData.currentCoverageOptions, invVehData.id)
    end

    sanitizedData = {
      id = insuranceInfo.id,
      name = insuranceInfo.name,
      image = insuranceInfo.image and ("gameplay/insurance/providers/" .. insuranceInfo.image .. ".png") or nil,
      color = insuranceInfo.color,
      perks = insuranceInfo.perks,
      paperworkFees = insuranceInfo.paperworkFees,
      canPayPaperworkFees = overhaul_career_economy_payment.canPay({money = {amount = insuranceInfo.paperworkFees, canBeNegative = false}}),
      slogan = insuranceInfo.slogan,
      carsInsuredCount = #carsInsured,
      carsInsured = carsInsured,
      totalInsuranceVehsValue = getTotalInsuranceVehsValue(insuranceInfo.id),
      renewsIn = getRenewsIn(insuranceInfo.id),
      renewsEvery = insuranceRenewalDistance / 1000,
      proRatedPercentage = getRenewsIn(insuranceInfo.id) * 1000 / insuranceRenewalDistance * 100,
      currentPremiumDetails = calculateInsurancePremium(insuranceInfo.id),
      coverageOptionsData = sanitizeCoverageOptions(insuranceInfo.id, plCoverageOptions),
      baseDeductibledData = {
        price = insuranceInfo.coverageOptions.deductible.choices[2].value,
        perkData = nil,
      },
      groupDiscountData = {
        groupDiscountTiers = deepcopy(groupDiscountTiers),
        currentTierData = currentTierData,
      },
    }

    if reduceDeductiblePerk then
      local isSignaturePerk = insuranceInfo.perks.reduceDeductible.isSignaturePerk or false
      sanitizedData.baseDeductibledData.perkData = formatPerkIconData(string.format("- %i%%", reduceDeductiblePerk * 100), string.format("Your %s insurance reduces your deductible by %i%%!", insuranceInfo.name, reduceDeductiblePerk * 100), reduceDeductiblePerk, isSignaturePerk)
      sanitizedData.baseDeductibledData.oldPrice = insuranceInfo.coverageOptions.deductible.choices[2].oldValue
    end

    local groupDiscountData = sanitizedData.groupDiscountData
    if currentTierData.id > 0 then
      groupDiscountData.groupDiscountTiers[currentTierData.id].isCurrent = true
    end
    if groupDiscountData.currentTierData.id > 0 then
      groupDiscountData.mainText = "Multi-Vehicle Discount Active"
      groupDiscountData.secondaryText = "Insurance discounts are based on the total value of your fleet."
    end

    return sanitizedData
  end

  local function getSanitizedInsuranceDataForPurchase(insuranceId, vehicleInfo)
    local sanitizedData = getInsuranceSanitizedData(insuranceId)
    local futureTierData = getInsuranceGroupDiscountTierData(insuranceId, vehicleInfo.Value)
    local newVehiclePremium = calculateVehiclePremium(nil, {vehValue = vehicleInfo.Value, insuranceId = insuranceId}).cost
    sanitizedData.vehicleName = vehicleInfo.Name
    sanitizedData.vehicleValue = vehicleInfo.Value
    sanitizedData.addVehiclePrice = calculateAddVehiclePrice(insuranceId, vehicleInfo.Value)
    sanitizedData.amountDue = sanitizedData.addVehiclePrice
    sanitizedData.nonProRatedVehiclePremium = newVehiclePremium
    sanitizedData.proRatedVehiclePremium = calculateAddOnVehicleProRatedPrice(insuranceId, vehicleInfo.Value, sanitizedData.groupDiscountData.currentTierData)
    sanitizedData.futurePremiumDetails = calculateInsurancePremium(insuranceId, nil, nil, vehicleInfo.Value)
    sanitizedData.groupDiscountData.futureTierData = futureTierData
    sanitizedData.groupDiscountData.willBumpTheirDiscount = (sanitizedData.groupDiscountData.currentTierData and futureTierData) and sanitizedData.groupDiscountData.currentTierData.id < futureTierData.id and not sanitizedData.groupDiscountData.willBumpTheirDiscount
    sanitizedData.groupDiscountData.willHaveGroupDiscountForTheFirstTime = sanitizedData.carsInsuredCount >= 1 and futureTierData.id > 0 and sanitizedData.groupDiscountData.currentTierData.id == 0
    if sanitizedData.groupDiscountData.futureTierData.id ~= sanitizedData.groupDiscountData.currentTierData.id then
      if sanitizedData.groupDiscountData.willHaveGroupDiscountForTheFirstTime then
        sanitizedData.groupDiscountData.mainText = "Multi-Vehicle Discount Available"
      else
        sanitizedData.groupDiscountData.mainText = "Bigger Discount Available"
      end
      sanitizedData.groupDiscountData.secondaryText = string.format("Adding this vehicle will advance you to Tier %i with a %i%% discount on your insurance !", sanitizedData.groupDiscountData.futureTierData.id, sanitizedData.groupDiscountData.futureTierData.discount * 100)
    end
    return sanitizedData
  end

  -- Helper function to create "No insurance" card
  local function createNoInsuranceCard()
    return {
      id = -1,
      name = "No insurance",
      perks = {
        {
          id = "noInsurance",
          intro = "Full repair cost",
          value = 0,
          valueType = "boolean",
        },
        {
          id = "noInsurance",
          intro = "No coverage",
          value = 0,
          valueType = "boolean",
        },
        {
          id = "noInsurance",
          intro = "Not recommended",
          value = 0,
          valueType = "boolean",
        },
      },
      initialBuyPrice = 0,
      slogan = "No insurance",
      --imagePath = "gameplay/insurance/providers/noInsurance.jpg",
      baseRenewalPriceData = {
        price = 0,
        perkData = nil,
      },
      baseDeductibledData = {
        price = 0,
        perkData = nil,
      },
    }
  end

  local function getCoverageRefundPrice(invVehId)
    local invVeh = getInvVehDataById(invVehId)
    if not invVeh then return 0 end
    local insuranceId = invVeh.insuranceId or -1
    if insuranceId == -1 then return 0 end
    return calculateVehiclePremium(invVehId).cost * getRenewsIn(insuranceId) * 1000 / insuranceRenewalDistance
  end

  local function getEarlyTerminationPenalty(invVehId)
    return getCoverageRefundPrice(invVehId) * earlyTerminationPenalty / 100
  end

  local function getNetRefundPrice(invVehId)
    return getCoverageRefundPrice(invVehId) - getEarlyTerminationPenalty(invVehId)
  end
  -- returns negative if ows money, positive if due money

  return {
    calculateAddVehiclePrice = calculateAddVehiclePrice,
    calculateInsurancePremium = calculateInsurancePremium,
    calculateVehiclePremium = calculateVehiclePremium,
    createNoInsuranceCard = createNoInsuranceCard,
    formatPerkIconData = formatPerkIconData,
    getActualRepairPrice = getActualRepairPrice,
    getApplicableInsuranceClass = getApplicableInsuranceClass,
    getCoverageRefundPrice = getCoverageRefundPrice,
    getEarlyTerminationPenalty = getEarlyTerminationPenalty,
    getInsuranceClassFromVehicleShoppingData = getInsuranceClassFromVehicleShoppingData,
    getInsuranceGroupDiscountTierData = getInsuranceGroupDiscountTierData,
    getInsuranceSanitizedData = getInsuranceSanitizedData,
    getInsurancesByClass = getInsurancesByClass,
    getInvVehsUnderClass = getInvVehsUnderClass,
    getInvVehsUnderInsurance = getInvVehsUnderInsurance,
    getNetRefundPrice = getNetRefundPrice,
    getRenewsIn = getRenewsIn,
    getSanitizedInsuranceDataForPurchase = getSanitizedInsuranceDataForPurchase,
    onOverhaulActive = onOverhaulActive,
    onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile,
    onUpdate = onUpdate,
    onVehicleSwitched = onVehicleSwitched,
    sanitizeCoverageOption = sanitizeCoverageOption,
    bindInputs = function(inputs)
      HOUSEKEEPING_INTERVAL = inputs.HOUSEKEEPING_INTERVAL
      M = inputs.M
      availableClasses = inputs.availableClasses
      availableInsurances = inputs.availableInsurances
      conditions = inputs.conditions
      driverScoreDecreaseDistance = inputs.driverScoreDecreaseDistance
      earlyTerminationPenalty = inputs.earlyTerminationPenalty
      gestures = inputs.gestures
      getDriverScoreTierData = inputs.getDriverScoreTierData
      getInvVehDataById = inputs.getInvVehDataById
      getPlCoverageOptionValue = inputs.getPlCoverageOptionValue
      groupDiscountTiers = inputs.groupDiscountTiers
      insuranceRenewalDistance = inputs.insuranceRenewalDistance
      inventoryVehNeedsRepair = inputs.inventoryVehNeedsRepair
      lastPos = inputs.lastPos
      loadInsurancesData = inputs.loadInsurancesData
      maxAccidentForgiveness = inputs.maxAccidentForgiveness
      maxLoyaltyPerCarAndRenewal = inputs.maxLoyaltyPerCarAndRenewal
      maximumDriverScore = inputs.maximumDriverScore
      minLoyaltyPerCarAndRenewal = inputs.minLoyaltyPerCarAndRenewal
      safeDrivingScoreIncrease = inputs.safeDrivingScoreIncrease
      saveInsurancesData = inputs.saveInsurancesData
      setActiveInsurance = inputs.setActiveInsurance
      vec3Zero = inputs.vec3Zero
    end,
  }
end

return partFactory
