-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Repair screen: the insurance and roadside repair menu, its quotes, payment and the repair tether.
-- Fork of stock lua/ge/extensions/career/modules/insurance/repairScreen.lua (BeamNG 0.40); read it top to bottom.
local M = {}
local careerContext = require("overhaul/lib/career/context")

local originComputerId
local vehicleToRepairData
local tether
local tetherRange = 7 -- meters
local roadsideMode = false
local roadsideTetherRange = 14 -- meters
local CONVENIENCE_FEE_MULT = 1.15
local getRepairData
local repairSubmitted = false
local closeMenuAfterSaving
local SAVE_WAIT_TIMEOUT = 180 -- real seconds; early save failures do not emit the vehicle-save hook

local function clearPendingRepair()
  closeMenuAfterSaving = nil
end

local function ownsRepairMenu()
  return careerContext.currentUiRouteName() == "overhaul.computer.repair"
end

local function applyConvenienceFee(amount)
  amount = tonumber(amount) or 0
  return math.ceil(amount * CONVENIENCE_FEE_MULT)
end

-- Roadside is instant-only. Always emit a real sequential array so Vue's
-- Array.prototype.find / .length work (empty {} or dict-keyed tables break the UI).
local function keepInstantRepairChoices(repairTimeOptions, fallbackChoice)
  if not repairTimeOptions then
    return
  end

  local instant = nil
  for _, choiceData in pairs(repairTimeOptions.choices or {}) do
    if type(choiceData) == "table" and tonumber(choiceData.value) == 0 then
      instant = deepcopy(choiceData)
      break
    end
  end

  if not instant then
    instant = deepcopy(fallbackChoice) or {
      id = 1,
      value = 0,
      premiumInfluence = 0,
      choiceText = _tr("ui.career.insurance.coverageChoice.instant"),
      totalPrice = 0,
      canPay = true,
    }
  end

  instant.id = instant.id or 1
  instant.value = 0
  instant.disabled = false
  instant.canPay = instant.canPay ~= false

  repairTimeOptions.choiceType = "multiple"
  repairTimeOptions.key = repairTimeOptions.key or "repairTime"
  repairTimeOptions.choices = { instant }
  repairTimeOptions.currentValueId = instant.id
end

local function hideRoadsidePopup()
  guihooks.trigger("roadsideRepairPopup", { visible = false })
end

local function closeRoadsidePopup()
  roadsideMode = false
  if tether then
    tether.remove = true
    tether = nil
  end
  hideRoadsidePopup()
end

local function getInstantChoice(repairTimeOptions)
  local choices = repairTimeOptions and repairTimeOptions.choices
  if type(choices) ~= "table" then
    return nil
  end
  return choices[1]
end

local function buildRoadsidePopupPayload()
  local data = getRepairData()
  if not data then
    return { visible = false }
  end
  local privateChoice = getInstantChoice(data.repairOptions.noInsuranceRepairData.repairTimeOptions)
  local privatePrice = privateChoice and privateChoice.totalPrice or data.vehicleData.damageCost

  local payload = {
    visible = true,
    vehicleName = data.vehicleData.name,
    invVehId = data.vehicleData.invVehId,
    private = {
      price = privatePrice,
      canPay = overhaul_career_economy_payment.canPay({ money = { amount = privatePrice, canBeNegative = false } }),
      repairTimeCost = privateChoice and privateChoice.premiumInfluence or 0,
      damageCost = data.vehicleData.damageCost,
      repairTimeOptionId = privateChoice and privateChoice.id,
    },
  }

  local insuranceData = data.repairOptions.insuranceRepairData
  if insuranceData then
    local insuranceChoice = getInstantChoice(insuranceData.repairTimeOptions)
    local insurancePrice = insuranceChoice and insuranceChoice.totalPrice or insuranceData.deductible
    payload.insurance = {
      price = insurancePrice,
      canPay = overhaul_career_economy_payment.canPay({ money = { amount = insurancePrice, canBeNegative = false } }),
      repairTimeCost = insuranceChoice and (insuranceChoice.premiumInfluence or 0) or 0,
      deductible = insuranceData.deductible,
      repairTimeOptionId = insuranceChoice and insuranceChoice.id,
    }
  end

  return payload
end

local function openRepairMenu(vehicle, _originComputerId, options)
  options = options or {}
  clearPendingRepair()
  vehicleToRepairData = vehicle
  repairSubmitted = false
  originComputerId = _originComputerId
  roadsideMode = options.roadside == true

  if tether then tether.remove = true end
  tether = nil
  if originComputerId then
    local computer = overhaul_world_facilities.getFacility("computer", originComputerId)
    if computer then
      local door = computer.doors and computer.doors[1]
      if door then
        tether = overhaul_career_maintenance_tether.startDoorTether(door, tetherRange, overhaul_career_career.closeAllMenus)
      end
      if not tether then
        local computerPos = overhaul_world_facilities.getAverageDoorPositionForFacility(computer)
        if computerPos then
          tether = overhaul_career_maintenance_tether.startSphereTether(computerPos, tetherRange, overhaul_career_career.closeAllMenus)
        end
      end
    end
  end

  extensions.ui_router.navigate("overhaul.computer.repair")
end

local function openRoadsideRepairMenu(vehicle)
  clearPendingRepair()
  vehicleToRepairData = vehicle
  repairSubmitted = false
  originComputerId = nil
  roadsideMode = true

  if tether then
    tether.remove = true
    tether = nil
  end

  local veh = be:getPlayerVehicle(0)
  if veh then
    tether = overhaul_career_maintenance_tether.startSphereTether(veh:getPosition(), roadsideTetherRange, closeRoadsidePopup)
  end

  guihooks.trigger("roadsideRepairPopup", buildRoadsidePopupPayload())
end

local function closeRepairMenu()
  if roadsideMode and not originComputerId then
    closeRoadsidePopup()
    return
  end
  roadsideMode = false
  if originComputerId then
    local computer = overhaul_world_facilities.getFacility("computer", originComputerId)
    overhaul_career_garage_computer.openMenu(computer)
  else
    overhaul_career_career.closeAllMenus()
  end
end

local function onOverhaulComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["vehicleInventory"] then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
    local inventoryId = vehicleData.inventoryId
    local computerFunctionData = {
      id = "repair",
      routeTarget = "overhaul.computer.repair",
      label = _tr("ui.career.shared.pathRepair"),
      callback = function() openRepairMenu(overhaul_career_garage_inventory.getVehicles()[inventoryId], menuData.computerFacility.id) end,
      order = 5
    }

    if not menuData.hasBoughtStarterVehicle then
      computerFunctionData.disabled = true
      computerFunctionData.reason = overhaul_career_garage_computer.reasons.hasBoughtStarterVehicle
    end

    local reason = overhaul_career_permissions.getStatusForTag({"vehicleRepair"}, {inventoryId = inventoryId})
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

getRepairData = function()
  if not vehicleToRepairData then return nil end
  local insuranceModule = overhaul_career_repair_insurance
  local invVehs = insuranceModule.getInvVehs()
  local currentVehicle = overhaul_career_garage_inventory.getVehicles()[vehicleToRepairData.id]
  if not currentVehicle then return nil end
  local invVehInfo = deepcopy(currentVehicle)
  local invVehInsurance = invVehs and invVehs[invVehInfo.id]
  if not invVehInsurance and invVehs then
    invVehInsurance = invVehs[tostring(invVehInfo.id)]
  end
  if not invVehInsurance then
    log("E", "career.insurance.repairScreen", string.format("Missing invVehs entry for vehicle %s", tostring(invVehInfo.id)))
    return nil
  end
  local insuranceId = invVehInsurance.insuranceId

  local damageCost = overhaul_career_market_valueCalculator.getRepairDetails(invVehInfo).price
  if roadsideMode then
    damageCost = applyConvenienceFee(damageCost)
  end

  local data = {
    repairOptions = {
      noInsuranceRepairData = {
        repairTimeOptions = {},
        useInsurance = false,
      },
      insuranceRepairData = nil,
    },
    vehicleData = {
      damageCost = damageCost,
      name = overhaul_career_garage_inventory.getVehicleNiceNameTranslated(invVehInfo.id),
      initialValue = invVehInsurance.initialValue,
      invVehId = invVehInfo.id,
      thumbnail = (overhaul_career_garage_inventory.getVehicleThumbnail(invVehInfo.id) or "") .. "?" .. (invVehInfo.dirtyDate or ""),
      isInsured = (insuranceId or -1) > 0,
      needsRepair = true,
      roadside = roadsideMode,
    },
    playerAttributes = overhaul_career_economy_playerAttributes.getAllAttributes(),
    driverScoreTierData = insuranceModule.getDriverScoreTierData(),
    futureDriverScore = getFutureDriverScoreAfterClaim(insuranceId, insuranceModule, invVehInfo),
    driverScore = insuranceModule.getDriverScore(),
    roadside = roadsideMode,
  }

  if insuranceModule.doesInsuranceExist(insuranceId) then
    local deductible = insuranceModule.getPlCoverageOptionValue(invVehInfo.id, "deductible")
    if roadsideMode then
      deductible = applyConvenienceFee(deductible)
    end
    data.repairOptions.insuranceRepairData = {
      repairTimeOptions = {},
      useInsurance = true,
      renewsIn = insuranceModule.getRenewsIn(insuranceId),
      insuranceName = insuranceModule.getInsuranceName(insuranceId),
      currentPremium = insuranceModule.calculateInsurancePremium(insuranceId).totalPriceWithDriverScore,
      futurePremium = getFuturePremiumAfterClaim(insuranceId, insuranceModule, invVehInfo),
      deductible = deductible,
      accidentForgivenesses = insuranceModule.getAccidentForgivenessCount(insuranceId),
    }
  end

  local defaultRepairTimeChoiceData
  if insuranceModule.doesInsuranceExist(insuranceId) then
    defaultRepairTimeChoiceData = insuranceModule.sanitizeCoverageOption(insuranceId, "repairTime", invVehInfo.id)
    data.repairOptions.insuranceRepairData.repairTimeOptions = deepcopy(defaultRepairTimeChoiceData)
  end

  data.repairOptions.noInsuranceRepairData.repairTimeOptions = {
    name = _tr("insurance.perks.repairTime.name", "Repair time"),
    choiceType = "multiple",
    choices = {
      {id = 1, value = 0, premiumInfluence = roadsideMode and applyConvenienceFee(500) or 500, choiceText = _tr("ui.career.insurance.coverageChoice.instant")},
      {id = 2, value = 120, premiumInfluence = 350, choiceText = core_locales.contextTranslate("ui.career.insurance.coverageChoice.minutes", {count = 2})},
      {id = 3, value = 300, premiumInfluence = 150, choiceText = core_locales.contextTranslate("ui.career.insurance.coverageChoice.minutes", {count = 5})},
      {id = 4, value = 600, premiumInfluence = 50, choiceText = core_locales.contextTranslate("ui.career.insurance.coverageChoice.minutes", {count = 10})}
    },
    currentValueId = 1,
  }

  if insuranceModule.doesInsuranceExist(insuranceId) then
    for _, choiceData in pairs(data.repairOptions.insuranceRepairData.repairTimeOptions.choices) do
      if roadsideMode and choiceData.premiumInfluence then
        choiceData.premiumInfluence = applyConvenienceFee(choiceData.premiumInfluence)
      end
      if choiceData.id == defaultRepairTimeChoiceData.currentValueId then
        choiceData.totalPrice = data.repairOptions.insuranceRepairData.deductible
        choiceData.premiumInfluence = 0
        local hasFreeInstantRepairPerk = insuranceModule.getPerkValueByInsuranceId(insuranceId, "instantRepair")
        choiceData.secondaryText = hasFreeInstantRepairPerk and _tr("ui.career.repair.freePolicyPerk") or _tr("ui.career.repair.alreadyPaidPolicyCoverage")
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
    local canPay = overhaul_career_economy_payment.canPay({money = {amount = totalPrice, canBeNegative = false}})
    choiceData.totalPrice = totalPrice
    choiceData.canPay = canPay
    choiceData.repairTimePrice = choiceData.oldPremiumInfluence and choiceData.oldPremiumInfluence or choiceData.premiumInfluence
  end

  if roadsideMode then
    local privateInstant = data.repairOptions.noInsuranceRepairData.repairTimeOptions.choices
      and data.repairOptions.noInsuranceRepairData.repairTimeOptions.choices[1]
    keepInstantRepairChoices(data.repairOptions.noInsuranceRepairData.repairTimeOptions, privateInstant)
    if data.repairOptions.insuranceRepairData then
      keepInstantRepairChoices(data.repairOptions.insuranceRepairData.repairTimeOptions, {
        id = 1,
        value = 0,
        premiumInfluence = 0,
        choiceText = _tr("ui.career.insurance.coverageChoice.instant"),
        totalPrice = data.repairOptions.insuranceRepairData.deductible,
        canPay = true,
        repairTimePrice = 0,
      })
    end
  end

  return data
end

local function onMenuClosed()
  clearPendingRepair()
  if roadsideMode and not originComputerId then
    closeRoadsidePopup()
    return
  end
  roadsideMode = false
  if tether then tether.remove = true tether = nil end
end

local function closeMenu()
  if closeMenuAfterSaving then return end
  closeRepairMenu()
end

local function resolveRepairQuote(invVehId, request)
  if repairSubmitted or not vehicleToRepairData or vehicleToRepairData.id ~= invVehId or type(request) ~= "table" then
    return nil, {success = false, reason = "invalidRepair"}
  end
  local data = getRepairData()
  local option = data and data.repairOptions[request.repairOptionKey]
  if not option then return nil, {success = false, reason = "invalidOption"} end
  local choice
  for _, candidate in pairs(option.repairTimeOptions.choices or {}) do
    if candidate.id == request.repairTimeOptionId then choice = candidate break end
  end
  if not choice or choice.disabled or choice.totalPrice == nil then
    return nil, {success = false, reason = "invalidChoice"}
  end
  if tonumber(request.quotedPrice) ~= choice.totalPrice then
    ui_message("Repair quote changed. Review the updated price and confirm again.", 5, "warning")
    return nil, {success = false, reason = "quoteChanged"}
  end
  if choice.canPay == false then return nil, {success = false, reason = "insufficientFunds"} end
  return {
    repairTime = choice.value,
    isInsuranceRepair = option.useInsurance,
    cost = {
      repairTimeCost = choice.premiumInfluence or 0,
      deductible = option.useInsurance and option.deductible or data.vehicleData.damageCost,
    },
  }
end

local function startRepairAtRoadside(invVehId, repairOptionData)
  repairOptionData = repairOptionData or {}
  repairOptionData.repairTime = 0

  -- Fee is already baked into the prices shown by getRepairData when roadsideMode is on.
  if tether then tether.remove = true tether = nil end
  roadsideMode = false
  hideRoadsidePopup()
  return overhaul_career_repair_insurance.startRepairInPlace(invVehId, repairOptionData, function()
    overhaul_career_career.closeAllMenus()
  end)
end

local function startRepairInGarage(invVehId, repairOptionData)
  local resolved, failure = resolveRepairQuote(invVehId, repairOptionData)
  if not resolved then
    if roadsideMode and not repairSubmitted then
      guihooks.trigger("roadsideRepairPopup", buildRoadsidePopupPayload())
    end
    return failure
  end
  repairSubmitted = true
  repairOptionData = resolved
  if roadsideMode then
    startRepairAtRoadside(invVehId, repairOptionData)
    return {success = true}
  end

  -- Thumbnail capture temporarily hides the UI. Reopening the computer before
  -- the vehicle-save hook steals controller focus from the restored menu.
  if tether then tether.remove = true tether = nil end
  local pending = {elapsed = 0}
  closeMenuAfterSaving = pending
  local function repairFinished(vehInfo, reason, committed)
    if closeMenuAfterSaving ~= pending then return end
    if not ownsRepairMenu() then clearPendingRepair() return end
    if vehInfo == false then
      pending.failed = true
      clearPendingRepair()
      repairSubmitted = committed == true
      ui_message(reason or "Repair could not finish. Review your vehicle and try again.", 10, "warning")
      return
    end
    pending.repaired = true
    pending.previousSave = overhaul_career_saveSystem.isSaveBusy()
    -- No thumbnail save is requested with autosave off. Respect that setting
    -- and return as soon as replacement finishes, without waiting for a hook.
    if not overhaul_career_career.isAutosaveEnabled() then
      clearPendingRepair()
      closeRepairMenu()
    end
  end
  local ok, result = pcall(overhaul_career_repair_insurance.startRepairInGarage, invVehId, repairOptionData, repairFinished)
  if not ok or result == false then
    clearPendingRepair()
    repairSubmitted = false
    log("W", "repairScreen", "Garage repair could not start: " .. tostring(result))
    ui_message("Repair could not start. Review the quote and try again.", 5, "warning")
    return {success = false, reason = "repairFailed"}
  end
  if pending.failed then return {success = false, reason = "repairFailed"} end
  return {success = true}
end

-- Ignore a save already running when repair was submitted: its thumbnail may
-- precede replacement, and a second capture can still hide the reopened menu.
local function onOverhaulSaveCurrentProfileAsyncStart()
  if closeMenuAfterSaving and closeMenuAfterSaving.repaired then
    closeMenuAfterSaving.previousSave = false
    closeMenuAfterSaving.saving = true
  end
end

local function onOverhaulSaveFinished()
  if closeMenuAfterSaving then closeMenuAfterSaving.previousSave = false end
end

local function onOverhaulSaveFailed()
  local pending = closeMenuAfterSaving
  if not pending or not pending.repaired then return end
  if pending.previousSave then
    pending.previousSave = false
    return
  end
  -- Initial info.json failures precede AsyncStart. The scheduler already tells
  -- the player; release Back but keep repairSubmitted to prevent another charge.
  clearPendingRepair()
end

local function onOverhaulVehicleSaveFinished()
  if not closeMenuAfterSaving or not closeMenuAfterSaving.saving then return end
  if not ownsRepairMenu() then clearPendingRepair() return end
  clearPendingRepair()
  closeRepairMenu()
end

local function onUpdate(dtReal)
  if not closeMenuAfterSaving then return end
  if not ownsRepairMenu() then clearPendingRepair() return end
  closeMenuAfterSaving.elapsed = closeMenuAfterSaving.elapsed + (dtReal or 0)
  if closeMenuAfterSaving.elapsed < SAVE_WAIT_TIMEOUT then return end
  clearPendingRepair()
  ui_message("The repair save did not finish. Check your vehicle before leaving the game.", 10, "warning")
  closeRepairMenu()
end

local function onOverhaulActive(active)
  if active == false then clearPendingRepair() end
end

M.getRepairData = getRepairData
M.openRepairMenu = openRepairMenu
M.openRoadsideRepairMenu = openRoadsideRepairMenu
M.closeRepairMenu = closeRepairMenu
M.closeRoadsidePopup = closeRoadsidePopup
M.closeMenu = closeMenu
M.startRepairInGarage = startRepairInGarage
M.isRoadsideMode = function() return roadsideMode end

M.onOverhaulComputerAddFunctions = onOverhaulComputerAddFunctions
M.onMenuClosed = onMenuClosed
M.onOverhaulVehicleSaveFinished = onOverhaulVehicleSaveFinished
M.onOverhaulSaveCurrentProfileAsyncStart = onOverhaulSaveCurrentProfileAsyncStart
M.onOverhaulSaveFinished = onOverhaulSaveFinished
M.onOverhaulSaveFailed = onOverhaulSaveFailed
M.onUpdate = onUpdate
M.onOverhaulActive = onOverhaulActive
M.onClientEndMission = clearPendingRepair
M.onExtensionUnloaded = clearPendingRepair

return M
