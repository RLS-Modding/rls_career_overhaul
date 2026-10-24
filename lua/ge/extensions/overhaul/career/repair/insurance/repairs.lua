-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Condition repair, test-drive damage, claims and the actual repairs (instant, delayed, in place, in garage).
-- Map: Market value and inventory checks; Test drive damage; Repair claims; Repair delivery; Exports.

-- Part of the Overhaul fork of stock lua/ge/extensions/career/modules/insurance/insurance.lua.

local recordClaim = require("overhaul/lib/progression/logbookFeed").register("overhaul.insuranceClaim", {
  title = "Insurance repair claimed", label = "Insurance", icon = "wrench"
}, "career/repair/insurance/repairs.lua")

local recordRepair = require("overhaul/lib/progression/logbookFeed").register("overhaul.vehicleRepaired", {
  title = "Vehicle repaired", label = "Maintenance", icon = "carCoins"
}, "career/repair/insurance/repairs.lua")

local condition = require('overhaul/lib/vehicles/condition')
local repairConfig = require('overhaul/lib/repair/operationSettings')

local partFactory = {}

function partFactory.new(inputs)
  local insuranceState = inputs.state
  local wiring = {}
  local tetherRange = 7
  local repairBusy = {}

  -- Market value and inventory checks -----------------------------------------------------------

  local function inventoryVehNeedsRepair(vehInvId)
    local vehInfo = overhaul_career_garage_inventory.getVehicles()[vehInvId]
    if not vehInfo then return end
    return overhaul_career_market_valueCalculator.partConditionsNeedRepair(vehInfo.partConditions)
  end

  -- Crash repair keeps repaired conditions while resetting unselected damage through the shared mask.
  local repairPartConditions = condition.repairCrashDamage

  -- Test drive damage ---------------------------------------------------------------------------

  local function getTestDriveChargeForPartConditions(vehId, partConditions)
    if not overhaul_career_market_valueCalculator.partConditionsNeedRepair(partConditions) then return 0 end
    local currentRepair = overhaul_career_market_valueCalculator.getSpawnedVehicleRepairPrice(vehId, partConditions)
    local deltaRepair = math.max(0, (tonumber(currentRepair) or 0) - (tonumber(insuranceState.testDriveBaselineRepair) or 0))
    return math.floor(deltaRepair * wiring.testDriveDamagePlayerShare + 0.5)
  end

  local function onOverhaulTestDriveStarted()
    local vehId = be:getPlayerVehicleID(0)
    local veh = getObjectByID(vehId)
    insuranceState.testDriveBaselineReady = false
    insuranceState.liveTestDriveCharge = 0
    insuranceState.lastTestDriveEstimateRequest = -math.huge
    if not veh then
      insuranceState.testDriveVehId = nil
      insuranceState.testDriveBaselineRepair = 0
      return
    end
    insuranceState.testDriveVehId = vehId
    core_vehicleBridge.requestValue(veh,
      function(res)
        insuranceState.testDriveBaselineRepair = overhaul_career_market_valueCalculator.getSpawnedVehicleRepairPrice(vehId, res.result)
        insuranceState.testDriveBaselineReady = insuranceState.testDriveVehId == vehId
      end,
      'getPartConditions')
  end

  local function refreshTestDriveChargeEstimate(vehId)
    vehId = vehId or insuranceState.testDriveVehId
    if not vehId or vehId ~= insuranceState.testDriveVehId then return end
    local veh = getObjectByID(vehId)
    if not veh then return end
    insuranceState.lastTestDriveEstimateRequest = os.clock()
    core_vehicleBridge.requestValue(veh,
      function(res)
        if vehId ~= insuranceState.testDriveVehId or not insuranceState.testDriveBaselineReady then return end
        insuranceState.liveTestDriveCharge = getTestDriveChargeForPartConditions(vehId, res.result)
      end,
      'getPartConditions')
  end

  -- Books the test-drive charge as a claim: payment, log, history entry.
  local function chargeTestDriveDamage(charge, vehId)
    insuranceState.lastTestDriveCharge = charge
    local label = string.format("Test drive vehicle damaged: -%i$", charge)
    ui_message(label, 5, "testDriveDamageClaim")

    local testInfo = overhaul_career_market_inspectVehicle.getSpawnedVehicleInfo()
    overhaul_career_economy_payment.pay({money = {amount = charge, canBeNegative = true}}, require("overhaul/lib/finance/metadata").tag({label = label}, "repair", {vehicleObjectId = vehId, vehicleName = testInfo and testInfo.name or "Test drive vehicle"}))
    overhaul_career_ui_log.addLog(string.format("Filed test drive damage claim for %.2f", charge), "insurance")

    local vehName = "Test drive vehicle"
    local spawnedInfo = overhaul_career_market_inspectVehicle.getSpawnedVehicleInfo()
    if spawnedInfo and spawnedInfo.name then
      vehName = spawnedInfo.name
    end

    overhaul_career_repair_insuranceHistory.addToPlHistory({
      type = "testDriveClaim",
      title = "Test drive vehicle damaged",
      effects = {{type = "money", label = "Money", changedBy = -charge, newValue = overhaul_career_economy_playerAttributes.getAttributeValue("money")}},
      concernedInsuranceName = "Test Drive",
      other = {
        vehName = vehName
      }
    })
  end

  local function handleTestDriveEndDamage(vehId, onComplete)
    insuranceState.testDriveVehId = nil
    insuranceState.testDriveBaselineReady = false
    insuranceState.liveTestDriveCharge = 0
    local veh = getObjectByID(vehId)
    if not veh then
      insuranceState.testDriveBaselineRepair = 0
      if onComplete then onComplete() end
      return
    end
    core_vehicleBridge.requestValue(veh,
      function(res)
        local partConditions = res.result
        local needsRepair = overhaul_career_market_valueCalculator.partConditionsNeedRepair(partConditions)
        if not needsRepair then
          insuranceState.testDriveBaselineRepair = 0
          insuranceState.lastTestDriveCharge = 0
          if onComplete then onComplete() end
          return
        end

        local charge = getTestDriveChargeForPartConditions(vehId, partConditions)

        if charge <= 0 then
          insuranceState.testDriveBaselineRepair = 0
          insuranceState.lastTestDriveCharge = 0
          if onComplete then onComplete() end
          return
        end

        chargeTestDriveDamage(charge, vehId)
        insuranceState.testDriveBaselineRepair = 0
        if onComplete then onComplete() end
      end,
      'getPartConditions')
  end

  local function makeTestDriveDamageClaim(vehId)
    handleTestDriveEndDamage(vehId)
  end

  -- Repair claims ------------------------------------------------------------------------------

  -- Mission callers pass an attribute table instead of a numeric deductible.
  local function getDeductibleValue(costs)
    local deductibleValue = type(costs) == "table" and costs.deductible or nil
    if type(deductibleValue) == "table" then
      deductibleValue = (tonumber(deductibleValue.money) or 0) + (tonumber(deductibleValue.vouchers) or 0)
    end
    return tonumber(deductibleValue) or 0
  end

  local function getInsuranceRepairDriverScorePenalty(vehInfo, costs, damageEstimate)
    damageEstimate = damageEstimate or (vehInfo and overhaul_career_market_valueCalculator.getRepairDetails(vehInfo).price or 0)
    local deductible = getDeductibleValue(costs)
    local covered = math.max(0, damageEstimate - deductible)
    if covered <= 0 then
      return 1
    end
    local penalty = math.max(2, math.ceil(math.sqrt(covered / wiring.insuranceRepairScorePenaltySqrtDivisor)) + 1)
    return math.min(penalty, wiring.insuranceRepairScorePenaltyMax)
  end

  -- Sums money and voucher costs; a bare number counts as money.
  local function totalRepairCosts(costs)
    local totalMoneyCost = 0
    local totalVoucherCost = 0
    for _, cost in pairs(costs) do
      if type(cost) == "number" then
        totalMoneyCost = totalMoneyCost + cost
      elseif type(cost) == "table" then
        totalMoneyCost = totalMoneyCost + (tonumber(cost.money) or 0)
        totalVoucherCost = totalVoucherCost + (tonumber(cost.vouchers) or 0)
      end
    end
    return totalMoneyCost, totalVoucherCost
  end

  -- Accident forgiveness absorbs the claim once; otherwise the driver score takes the penalty.
  local function applyClaimToDriverRecord(insuranceId, driverScorePenalty)
    local policy = insuranceId > 0 and insuranceState.plInsurancesData[insuranceId]
    if policy and policy.accidentForgiveness > 0 then
      policy.accidentForgiveness = policy.accidentForgiveness - 1
      return true
    end
    insuranceState.plDriverScore = math.max(insuranceState.plDriverScore - driverScorePenalty, wiring.minimumDriverScore)
    return false
  end

  local function makeRepairClaim(invVehId, costs, vehInfo, damageEstimate)
    local invVehData = insuranceState.invVehs[invVehId] or wiring.getInvVehDataById(invVehId)
    if not invVehData then return end
    costs = type(costs) == "table" and costs or {}

    local totalMoneyCost, totalVoucherCost = totalRepairCosts(costs)

    local insuranceId = invVehData.insuranceId or -1
    local driverScorePenalty = getInsuranceRepairDriverScorePenalty(vehInfo, costs, damageEstimate)
    local hasUsedAccidentForgiveness = applyClaimToDriverRecord(insuranceId, driverScorePenalty)

    insuranceState.lastDriverScoreKmIncrease = insuranceState.totalDrivenDistance
    insuranceState.lastDriverScoreInsuredKmIncrease = insuranceState.insuredDrivenDistance or 0

    local insuranceName = "None"
    if insuranceId > 0 and wiring.availableInsurances[insuranceId] then
      insuranceName = wiring.availableInsurances[insuranceId].name
    end

    local scoreEffectChange = hasUsedAccidentForgiveness and 0 or -driverScorePenalty
    local effects = {{type = "money", label = "Money", changedBy = -totalMoneyCost, newValue = overhaul_career_economy_playerAttributes.getAttributeValue("money")}}
    if totalVoucherCost > 0 then
      table.insert(effects, {type = "vouchers", label = "Vouchers", changedBy = -totalVoucherCost, newValue = overhaul_career_economy_playerAttributes.getAttributeValue("vouchers")})
    end
    table.insert(effects, {type = "driverScore", label = "Driver score", changedBy = scoreEffectChange, newValue = insuranceState.plDriverScore})

    local deductibleValue = getDeductibleValue(costs)
    overhaul_career_repair_insuranceHistory.addToPlHistory({
      type = "insuranceRepairClaim",
      title = "Insurance repair claim",
      effects = effects,
      concernedInsuranceName = insuranceName,
      overrideText = hasUsedAccidentForgiveness and "Use accident forgiveness" or nil,
      other = {
        vehDamagePrice = damageEstimate or (vehInfo and overhaul_career_market_valueCalculator.getRepairDetails(vehInfo).price or 0),
        deductible = deductibleValue
      }
    })

    overhaul_career_ui_log.addLog(string.format("Filed repair claim for vehicle %s on insurance %s: cost %.2f money / %.2f vouchers, deductible %.2f, accident forgiveness %s, driver score now %d",
      tostring(invVehId), wiring.M.getInsuranceName(insuranceId), totalMoneyCost, totalVoucherCost, deductibleValue,
      hasUsedAccidentForgiveness and "used" or "not used", tonumber(insuranceState.plDriverScore) or 0), "insurance")

    overhaul_career_garage_inventory.addAccident(invVehId)
    overhaul_career_garage_inventory.setVehicleDirty(invVehId)
    extensions.hook("onOverhaulInsuranceRepairClaim")
    gameplay_achievement.unlockAchievement("CLAIM_FILED")
  end

  -- Repair delivery -----------------------------------------------------------------------------

  local function onAfterVehicleRepaired(vehInfo)
    overhaul_career_garage_inventory.setVehicleDirty(vehInfo.id)
    local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(vehInfo.id)
    if vehId then
      overhaul_career_maintenance_fuel.minimumRefuelingCheck(vehId)
      if gameplay_walk.isWalking() then
        local veh = getObjectByID(vehId)
        gameplay_walk.setRot(veh:getPosition() - getPlayerVehicle(0):getPosition())
      end
    end

    overhaul_career_saveSystem.saveCurrent({vehInfo.id}, {force = true})
  end

  local function refreshUiAfterGarageDespawn()
    overhaul_career_garage_inventory.sendVehicleUpdatesToUi()
    if overhaul_career_garage_computer and overhaul_career_garage_computer.refreshMenu then
      overhaul_career_garage_computer.refreshMenu(true)
    end
  end

  local function startRepairDelayed(vehInfo, repairTime, callback)
    if overhaul_career_garage_inventory.getVehicleIdFromInventoryId(vehInfo.id) then -- vehicle is currently spawned
      overhaul_career_garage_inventory.removeVehicleObject(vehInfo.id, true)
      refreshUiAfterGarageDespawn()
    end
    overhaul_career_garage_inventory.delayVehicleAccess(vehInfo.id, repairTime, "repair")
    if callback then callback(vehInfo) end
    onAfterVehicleRepaired(vehInfo)
  end

  local function getDriverScoreTierData(score)
    if not score then score = insuranceState.plDriverScore end
    for _, tierData in pairs(insuranceState.driverScoreTiers) do
      if score >= tierData.min and score <= tierData.max then
        return tierData
      end
    end
    return insuranceState.driverScoreTiers[#insuranceState.driverScoreTiers]
  end

  local function getDriverScore()
    return insuranceState.plDriverScore
  end

  local function missionStartRepairCallback(vehInfo)
    if not vehInfo then return end
    guihooks.trigger('MenuOpenModule','menu.careermission')
    guihooks.trigger('gameContextPlayerVehicleDamageInfo', {needsRepair = inventoryVehNeedsRepair(vehInfo.id)})
  end

  local function startRepairInstant(vehInfo, callback, skipSound, prepareRepair)
    if not skipSound then
      Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Vehicle_Recover')
    end

    local completed = false
    local function complete(success, reason)
      if completed then return end
      completed = true
      if success == false then
        if callback then callback(false, reason) end
        return
      end
      if callback then callback(vehInfo) end
      onAfterVehicleRepaired(vehInfo)
    end
    if overhaul_career_garage_inventory.getVehicleIdFromInventoryId(vehInfo.id) then
      -- A full paid repair clears the outgoing snapshot after capture, before replacement.
      overhaul_career_garage_inventory.spawnVehicle(vehInfo.id, 2, complete, nil, nil,
        {prepareReplacement = prepareRepair or function()
          overhaul_career_repair_damageManager.clearDamageState(vehInfo.id)
          return true
        end})
      return function() completed = true end
    end
    complete()
    return function() completed = true end
  end

  -- Debits the quote, records committed work and refunds failures before commitment.
  local function startRepair(vehInvId, repairOptionData, callback)
    vehInvId = vehInvId or overhaul_career_garage_inventory.getCurrentVehicle()
    if vehInvId and repairBusy[vehInvId] then return false end
    -- Only an explicit quote authorizes repair; opening a service is not a repair purchase.
    local costs = type(repairOptionData) == "table" and repairOptionData.cost
    if type(costs) ~= "table" or next(costs) == nil then return false end
    local vehInfo = overhaul_career_garage_inventory.getVehicles()[vehInvId]
    if not vehInfo then return end
    local totalCost = 0
    for _, cost in pairs(costs) do
      if type(cost) ~= "number" or cost ~= cost or cost < 0 or cost == math.huge then return false end
      totalCost = totalCost + cost
    end
    if totalCost == math.huge then return false end

    local operation = {elapsed = 0}
    repairBusy[vehInvId] = operation
    if totalCost > 0 then
      if not overhaul_career_economy_payment.pay({money = {amount = totalCost, canBeNegative = true}}, {
        category = "repair", finance = {vehicleId = vehInvId, vehicleName = vehInfo.niceName},
        label = core_locales.contextTranslate("ui.career.insurance.payment.repairedVehicle", {name = overhaul_career_garage_inventory.getVehicleNiceNameTranslated(vehInvId)})}) then
        repairBusy[vehInvId] = nil
        return false
      end
      Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
    end

    local damageEstimate = overhaul_career_market_valueCalculator.getRepairDetails(vehInfo).price
    local committed, paymentRecorded, completed = false, false, false
    local cancelInstant
    -- A failed capture has not repaired the car and must not create a paid repair history entry.
    local function recordPayment()
      if paymentRecorded then return end
      paymentRecorded = true
      local detail = vehInfo.niceName or "Vehicle"
      if repairOptionData.isInsuranceRepair then
        recordClaim({name = detail, money = -totalCost})
      else
        recordRepair({name = detail, money = -totalCost})
      end
      if repairOptionData.isInsuranceRepair then -- the player can repair on his own without insurance
        makeRepairClaim(vehInvId, repairOptionData.cost, vehInfo, damageEstimate)
      else
        overhaul_career_repair_insuranceHistory.addToPlHistory({
          type = "privateRepair",
          title = "Private repair",
          effects = {{type = "money", label = "Money", changedBy = -totalCost, newValue = overhaul_career_economy_playerAttributes.getAttributeValue("money")}},
          concernedInsuranceName = "Private repair",
          other = {damageCost = damageEstimate}
        })
        if totalCost >= 10000 then
          gameplay_achievement.unlockAchievement("THAT_WAS_EXPENSIVE")
        end
      end

      overhaul_career_ui_log.addLog(string.format("Repaired vehicle %s (%s) for %.2f, repair time %s",
        tostring(vehInvId), repairOptionData.isInsuranceRepair and "insurance" or "private", totalCost,
        tostring(repairOptionData.repairTime or 0)), "insurance")
    end

    -- the actual repair
    local paintRepair = wiring.getPlCoverageOptionValue(vehInvId, "paintRepair")
    local data = {
      partConditions = vehInfo.partConditions,
      paintRepair = paintRepair,
      inventoryId = vehInvId
    }
    local function prepareRepair()
      if completed then return false end
      if committed then return true end
      if overhaul_career_garage_inventory.getVehicles()[vehInvId] ~= vehInfo then return false end
      repairPartConditions(data)
      if overhaul_career_maintenance_tireSystem and overhaul_career_maintenance_tireSystem.clearFlatsForVehicle then
        overhaul_career_maintenance_tireSystem.clearFlatsForVehicle(vehInvId)
      end
      overhaul_career_repair_damageManager.clearDamageState(vehInvId)
      recordPayment()
      committed = true
      return true
    end

    if (repairOptionData and repairOptionData.repairTime) and repairOptionData.repairTime > 0 then
      if not prepareRepair() then
        repairBusy[vehInvId] = nil
        if totalCost > 0 then
          overhaul_career_economy_payment.pay({money = {amount = -totalCost, canBeNegative = true}},
            {category = "refund", finance = {vehicleId = vehInvId, vehicleName = vehInfo.niceName},
              label = "Vehicle repair refund: id " .. tostring(vehInvId)})
        end
        return false
      end
      startRepairDelayed(vehInfo, repairOptionData.repairTime, callback)
      repairBusy[vehInvId] = nil
    else
      local function complete(repaired, reason)
        if completed then return end
        completed = true
        if cancelInstant then cancelInstant() end
        if repairBusy[vehInvId] == operation then repairBusy[vehInvId] = nil end
        if repaired == false then
          if committed then
            -- Keep paid conditions and the cleared snapshot authoritative for later retrieval.
            if overhaul_career_garage_inventory.getVehicles()[vehInvId] == vehInfo then
              local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(vehInvId)
              if vehId and getObjectByID(vehId) then
                overhaul_career_garage_inventory.removeVehicleObject(vehInvId, true)
              end
              if not overhaul_career_garage_inventory.getVehicleIdFromInventoryId(vehInvId) then
                onAfterVehicleRepaired(vehInfo)
              end
            end
            local message = "Repair saved, but vehicle replacement failed. Retrieve the vehicle from inventory."
            log("W", "insurance", message .. " " .. tostring(reason))
            -- The third callback value prevents retrying an already paid repair.
            if callback then callback(false, message, true) end
            return
          elseif totalCost > 0 then
            overhaul_career_economy_payment.pay({money = {amount = -totalCost, canBeNegative = true}},
              {category = "refund", finance = {vehicleId = vehInvId, vehicleName = vehInfo.niceName},
                label = "Vehicle repair refund: id " .. tostring(vehInvId)})
          end
          if callback then callback(false, reason) end
          return
        end
        if callback then callback(repaired) end
      end
      operation.cancel = function(reason)
        if completed then return end
        log('W', 'insurance', reason .. ': id ' .. tostring(vehInvId))
        complete(false, reason)
      end
      if not overhaul_career_garage_inventory.getVehicleIdFromInventoryId(vehInvId) and not prepareRepair() then
        complete(false, "Vehicle changed before repair.")
        return
      end
      cancelInstant = startRepairInstant(vehInfo, complete, false, prepareRepair)
    end
  end

  -- Instant in-place repair (roadside spots, stay seated). No garage storage / teleport.
  local function startRepairInPlace(invVehId, repairOptionData, callback)
    repairOptionData = (repairOptionData and type(repairOptionData) == "table") and repairOptionData or {}
    repairOptionData.repairTime = 0

    if ui_fadeScreen and ui_fadeScreen.start then
      ui_fadeScreen.start(0.5)
    end

    local started = startRepair(invVehId, repairOptionData, function(vehInfo, reason, committed)
      if callback then
        if vehInfo == false then callback(false, reason, committed) else callback(vehInfo) end
      end
      if ui_fadeScreen and ui_fadeScreen.stop then
        ui_fadeScreen.stop(0.5)
      end
    end)
    if started == false and ui_fadeScreen and ui_fadeScreen.stop then
      ui_fadeScreen.stop(0.5)
    end
    return started
  end

  -- Timed repairs can move into garage storage. Instant keeps the car out (vanilla-style).
  local function startRepairInGarage(invVehId, repairOptionData, callback)
    repairOptionData = (repairOptionData and type(repairOptionData) == "table") and repairOptionData or {}
    local garage = overhaul_career_garage_inventory.getClosestGarage()
    local spaceInfo = overhaul_career_garage_garageManager.isGarageSpace(garage.id)
    local hasStorage = spaceInfo and spaceInfo[1]
    local isInstant = not repairOptionData.repairTime or repairOptionData.repairTime <= 0

    if hasStorage and not isInstant then
      local invVeh = overhaul_career_garage_inventory.getVehicle(invVehId)
      if invVeh then
        invVeh.location = garage.id
        invVeh.lastKnownLevel = getCurrentLevelIdentifier()
        invVeh.niceLocation = overhaul_career_garage_garageManager.garageIdToName(garage.id)
        overhaul_career_garage_inventory.setVehicleDirty(invVehId)
      end
    end

    local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(invVehId)
    extensions.hook("onOverhaulRepairInGarage", invVehId)
    return startRepair(invVehId, repairOptionData, function(vehInfo, reason, committed)
      if vehInfo and vehInfo ~= false and vehId and isInstant then
        local vehObj = getObjectByID(vehId)
        if vehObj then overhaul_world_facilities.teleportToGarage(garage.id, vehObj, false) end
      end
      if callback then callback(vehInfo, reason, committed) end
    end)
  end

  local function genericVehNeedsRepair(vehId, callback)
    local veh = getObjectByID(vehId)
    if not veh then return end
    core_vehicleBridge.requestValue(veh,
      function(res)
        local needsRepair = overhaul_career_market_valueCalculator.partConditionsNeedRepair(res.result)
        if needsRepair and vehId == insuranceState.testDriveVehId and insuranceState.testDriveBaselineReady then
          local charge = getTestDriveChargeForPartConditions(vehId, res.result)
          insuranceState.liveTestDriveCharge = charge
          needsRepair = charge > 0
        end
        callback(needsRepair)
      end,
      'getPartConditions')
  end

  -- Exports -------------------------------------------------------------------------------------

  local function resetRepairs(reason)
    local operations = repairBusy
    repairBusy = {}
    for _, operation in pairs(operations) do
      if operation.cancel then operation.cancel(reason) end
    end
  end

  local function onUpdate(dtReal)
    local expired = {}
    for _, operation in pairs(repairBusy) do
      operation.elapsed = operation.elapsed + dtReal
      if operation.elapsed >= repairConfig.get().replacementTimeoutS then expired[#expired + 1] = operation end
    end
    for _, operation in ipairs(expired) do
      if operation.cancel then operation.cancel('Vehicle repair timed out') end
    end
  end

  return {
    onUpdate = onUpdate,
    onOverhaulActive = function() resetRepairs('Career changed during vehicle repair') end,
    onClientEndMission = function() resetRepairs('Level unloaded during vehicle repair') end,
    onExtensionUnloaded = function() resetRepairs('Insurance unloaded during vehicle repair') end,
    genericVehNeedsRepair = genericVehNeedsRepair,
    getDriverScore = getDriverScore,
    getDriverScoreTierData = getDriverScoreTierData,
    getInsuranceRepairDriverScorePenalty = getInsuranceRepairDriverScorePenalty,
    handleTestDriveEndDamage = handleTestDriveEndDamage,
    inventoryVehNeedsRepair = inventoryVehNeedsRepair,
    makeRepairClaim = makeRepairClaim,
    makeTestDriveDamageClaim = makeTestDriveDamageClaim,
    missionStartRepairCallback = missionStartRepairCallback,
    onOverhaulTestDriveStarted = onOverhaulTestDriveStarted,
    refreshTestDriveChargeEstimate = refreshTestDriveChargeEstimate,
    repairPartConditions = repairPartConditions,
    startRepair = startRepair,
    startRepairInGarage = startRepairInGarage,
    startRepairInPlace = startRepairInPlace,
    startRepairInstant = startRepairInstant,
    tetherRange = tetherRange,
    bindInputs = function(inputs)
      wiring.M = inputs.M
      wiring.availableInsurances = inputs.availableInsurances
      wiring.getInvVehDataById = inputs.getInvVehDataById
      wiring.getPlCoverageOptionValue = inputs.getPlCoverageOptionValue
      wiring.insuranceRepairScorePenaltyMax = inputs.insuranceRepairScorePenaltyMax
      wiring.insuranceRepairScorePenaltySqrtDivisor = inputs.insuranceRepairScorePenaltySqrtDivisor
      wiring.minimumDriverScore = inputs.minimumDriverScore
      wiring.testDriveDamagePlayerShare = inputs.testDriveDamagePlayerShare
    end,
  }
end

return partFactory
