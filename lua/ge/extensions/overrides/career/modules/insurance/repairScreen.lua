local M = {}

M.dependencies = {'career_modules_valueCalculator', 'career_modules_inventory', 'career_modules_playerAttributes', 'career_modules_payment', 'career_modules_insurance_insurance'}

local originComputerId
local vehicleToRepairData

local function openRepairMenu(vehicle, _originComputerId)
  vehicleToRepairData = vehicle
  originComputerId = _originComputerId
  guihooks.trigger('ChangeState', {state = 'repair', params = {}})
end

local function closeRepairMenu()
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["vehicleInventory"] then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
    local inventoryId = vehicleData.inventoryId
    local computerFunctionData = {
      id = "repair",
      label = "Repair",
      callback = function() openRepairMenu(career_modules_inventory.getVehicles()[inventoryId], menuData.computerFacility.id) end,
      order = 5
    }

    if menuData.tutorialPartShoppingActive or menuData.tutorialTuningActive then
      computerFunctionData.disabled = true
      computerFunctionData.reason = {
        type = "text",
        label = "Disabled during tutorial. Use the recovery prompt instead."
      }
    end

    local reason = career_modules_permissions.getStatusForTag({"vehicleRepair"}, {inventoryId = inventoryId})
    if not reason.allow then
      computerFunctionData.disabled = true
    end
    if reason.permission ~= "allowed" then
      computerFunctionData.reason = reason
    end

    computerFunctions.vehicleSpecific[inventoryId][computerFunctionData.id] = computerFunctionData
  end
end

local function getClaimCostsPreview(invVehInfo, insuranceModule)
  return {deductible = insuranceModule.getPlCoverageOptionValue(invVehInfo.id, "deductible")}
end

local function getFutureDriverScoreAfterClaim(insuranceId, insuranceModule, invVehInfo)
  local plInsurancesData = insuranceModule.getPlayerInsurancesData()
  local plDriverScore = insuranceModule.getDriverScore()
  if insuranceId and plInsurancesData[insuranceId] and plInsurancesData[insuranceId].accidentForgiveness > 0 then
    return plDriverScore
  end
  local penalty = insuranceModule.getInsuranceRepairDriverScorePenalty(invVehInfo, getClaimCostsPreview(invVehInfo, insuranceModule))
  return math.max(plDriverScore - penalty, 0)
end

local function getFuturePremiumAfterClaim(insuranceId, insuranceModule, invVehInfo)
  local plInsurancesData = insuranceModule.getPlayerInsurancesData()
  local plDriverScore = insuranceModule.getDriverScore()

  if not insuranceId or not plInsurancesData[insuranceId] then return 0 end
  if plInsurancesData[insuranceId].accidentForgiveness > 0 then
    return insuranceModule.calculateInsurancePremium(insuranceId).totalPriceWithDriverScore
  end
  local penalty = insuranceModule.getInsuranceRepairDriverScorePenalty(invVehInfo, getClaimCostsPreview(invVehInfo, insuranceModule))
  local futureScore = math.max(plDriverScore - penalty, 0)
  local futureTierData = insuranceModule.getDriverScoreTierData(futureScore)
  return insuranceModule.calculateInsurancePremium(insuranceId).totalPrice * futureTierData.multiplier
end

local function getRepairData()
  local insuranceModule = career_modules_insurance_insurance
  local invVehs = insuranceModule.getInvVehs()
  local invVehInfo = deepcopy(vehicleToRepairData)
  local insuranceId = invVehs[invVehInfo.id].insuranceId

  local data = {
    repairOptions = {
      noInsuranceRepairData = {
        repairTimeOptions = {},
        useInsurance = false,
      },
      insuranceRepairData = nil,
    },
    vehicleData = {
      damageCost = career_modules_valueCalculator.getRepairDetails(invVehInfo).price,
      name = invVehInfo.niceName,
      initialValue = invVehs[invVehInfo.id].initialValue,
      invVehId = invVehInfo.id,
      thumbnail = career_modules_inventory.getVehicleThumbnail(invVehInfo.id) .. "?" .. (invVehInfo.dirtyDate or ""),
      isInsured = invVehs[invVehInfo.id].insuranceId > 0,
      needsRepair = true,
    },
    playerAttributes = career_modules_playerAttributes.getAllAttributes(),
    driverScoreTierData = insuranceModule.getDriverScoreTierData(),
    futureDriverScore = getFutureDriverScoreAfterClaim(insuranceId, insuranceModule, invVehInfo),
    driverScore = insuranceModule.getDriverScore(),
  }

  if insuranceModule.doesInsuranceExist(insuranceId) then
    data.repairOptions.insuranceRepairData = {
      repairTimeOptions = {},
      useInsurance = true,
      renewsIn = insuranceModule.getRenewsIn(insuranceId),
      insuranceName = insuranceModule.getInsuranceName(insuranceId),
      currentPremium = insuranceModule.calculateInsurancePremium(insuranceId).totalPriceWithDriverScore,
      futurePremium = getFuturePremiumAfterClaim(insuranceId, insuranceModule, invVehInfo),
      deductible = insuranceModule.getPlCoverageOptionValue(invVehInfo.id, "deductible"),
      accidentForgivenesses = insuranceModule.getAccidentForgivenessCount(insuranceId),
    }
  end

  local defaultRepairTimeChoiceData
  if insuranceModule.doesInsuranceExist(insuranceId) then
    defaultRepairTimeChoiceData = insuranceModule.sanitizeCoverageOption(insuranceId, "repairTime", invVehInfo.id)
    data.repairOptions.insuranceRepairData.repairTimeOptions = deepcopy(defaultRepairTimeChoiceData)
  end

  data.repairOptions.noInsuranceRepairData.repairTimeOptions = {
    name = translateLanguage("insurance.perks.repairTime.name", "Repair time", true),
    choiceType = "multiple",
    choices = {
      {id = 1, value = 0, premiumInfluence = 500, choiceText = "Instant"},
      {id = 2, value = 120, premiumInfluence = 350, choiceText = "2 min"},
      {id = 3, value = 300, premiumInfluence = 150, choiceText = "5 min"},
      {id = 4, value = 600, premiumInfluence = 50, choiceText = "10 min"}
    }
  }

  if insuranceModule.doesInsuranceExist(insuranceId) then
    for _, choiceData in pairs(data.repairOptions.insuranceRepairData.repairTimeOptions.choices) do
      if choiceData.id == defaultRepairTimeChoiceData.currentValueId then
        choiceData.totalPrice = data.repairOptions.insuranceRepairData.deductible
        choiceData.premiumInfluence = 0
        local hasFreeInstantRepairPerk = insuranceModule.getPerkValueByInsuranceId(insuranceId, "instantRepair")
        choiceData.secondaryText = hasFreeInstantRepairPerk and "Free (Policy Perk)" or "Already paid (Policy Coverage)"
        data.repairOptions.noInsuranceRepairData.repairTimeOptions.currentValueId = choiceData.id
      elseif choiceData.value == 0 then
        choiceData.totalPrice = choiceData.premiumInfluence + data.repairOptions.insuranceRepairData.deductible
      end
      if choiceData.id == defaultRepairTimeChoiceData.currentValueId or choiceData.value == 0 then
        choiceData.canPay = true
        choiceData.repairTimePrice = choiceData.premiumInfluence
        choiceData.disabled = false
      else
        choiceData.disabled = true
      end
    end
  end

  for _, choiceData in pairs(data.repairOptions.noInsuranceRepairData.repairTimeOptions.choices) do
    local totalPrice = choiceData.premiumInfluence + data.vehicleData.damageCost
    local canPay = career_modules_payment.canPay({money = {amount = totalPrice, canBeNegative = false}})
    choiceData.totalPrice = totalPrice
    choiceData.canPay = canPay
    choiceData.repairTimePrice = choiceData.oldPremiumInfluence and choiceData.oldPremiumInfluence or choiceData.premiumInfluence
  end

  return data
end

local function closeMenu()
  closeRepairMenu()
end

local function startRepairInGarage(invVehId, repairOptionData)
  closeRepairMenu()
  return career_modules_insurance_insurance.startRepairInGarage(invVehId, repairOptionData)
end

M.getRepairData = getRepairData
M.openRepairMenu = openRepairMenu
M.closeRepairMenu = closeRepairMenu
M.closeMenu = closeMenu
M.startRepairInGarage = startRepairInGarage

M.onComputerAddFunctions = onComputerAddFunctions

return M
