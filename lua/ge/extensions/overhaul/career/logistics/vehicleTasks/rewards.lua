-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Vehicle delivery tasks: rewards, completion and vehicle cleanup.
-- Part of the Overhaul fork of stock lua/ge/extensions/career/modules/delivery/vehicleTasks.lua.
-- Read reward projection, completion steps, vehicle cleanup and abandonment.
local part = {}

function part.new(inputs)
  local deliveryText = require("overhaul/lib/logistics/resultTranslations")
  local _tr = deliveryText.text
  local core_locales = {contextTranslate = deliveryText.context}
  local issued = require('overhaul/lib/vehicles/issued')
  local deliveryServices, taskState = assert(inputs.services), assert(inputs.state)
  local abandonFine = assert(type(inputs.abandonFine) == 'function' and inputs.abandonFine, 'rewards.abandonFine callback required')
  local callbacks = {}

  -- Reward calculation ----------------------------------------------------------------------------

  -- Delivery bonus tuning. "No delays" is judged against the offer distance driven at a modest average speed (12 m/s, about 43 km/h) plus a fixed allowance, not against the road the driver actually took.
  local EXPECTED_SPEED_M_PER_S = 12
  local EXPECTED_TIME_PADDING_S = 30
  -- Driven distance as a multiple of the offer distance; at or above it the delivery counts as a detour.
  local DETOUR_DISTANCE_RATIO = 1.2
  -- Offer distance assumed when the offer has none and nothing else is known.
  local MIN_OFFER_DISTANCE_M = 1000
  -- Share of the vehicle's parts broken (0..1) at which the whole reward is lost.
  local EXCESSIVE_DAMAGE_RATIO = 0.25

  -- Logs the finished vehicle, its damage, distance and time; returns the figures the rewards use.
  local function readDrivingFacts(taskData)
    log("I","","Finished Vehicle: " .. taskData.vehId)
    local brokenPartsNumber = tonumber(taskData.brokenPartsNumber) or 0
    local partsNumber = tonumber(taskData.partsNumber) or 0
    local brokenPartsRelative = partsNumber > 0 and brokenPartsNumber / partsNumber or 0
    log("I","",string.format("Broken Parts: %0.1f%% (%d / %d)", brokenPartsRelative*100, brokenPartsNumber, partsNumber))
    local startingOdometer = tonumber(taskData.offer.startingOdometer) or -1
    local endingOdometer = tonumber(taskData.offer.endingOdometer) or -1
    local distanceDriven = 0
    if startingOdometer ~= -1 and endingOdometer ~= -1 then
      distanceDriven = endingOdometer - startingOdometer
    end
    local offerData = taskData.offer.data or {}
    local originalDistance = tonumber(offerData.originalDistance)
    if not originalDistance or originalDistance <= 0 then
      if taskData.offer.origin and taskData.offer.destination and deliveryServices.generator and deliveryServices.generator.getDistanceBetweenFacilities then
        originalDistance = tonumber((deliveryServices.generator.getDistanceBetweenFacilities(taskData.offer.origin, taskData.offer.destination))) or 0
      end
      if not originalDistance or originalDistance <= 0 then
        originalDistance = math.max(distanceDriven, MIN_OFFER_DISTANCE_M)
      end
      offerData.originalDistance = originalDistance
    end
    log("I","",string.format("Driven Distance: %0.3fkm (%0.1f%% of allowed %0.3fkm)", distanceDriven/1000, 100*distanceDriven/originalDistance, DETOUR_DISTANCE_RATIO*originalDistance/1000))
    local timeTaken = deliveryServices.general.time() - taskData.startedTimestamp
    local expectedTime = (originalDistance / EXPECTED_SPEED_M_PER_S + EXPECTED_TIME_PADDING_S)
    log("I","",string.format("Time Taken: %0.1f seconds (expected: %0.1fs)", timeTaken, expectedTime))
    return {
      brokenPartsNumber = brokenPartsNumber,
      brokenPartsRelative = brokenPartsRelative,
      distanceDriven = distanceDriven,
      originalDistance = originalDistance,
      timeTaken = timeTaken,
      expectedTime = expectedTime,
    }
  end

  -- The reputation entries of a reward table; the damage and bonus rows scale these with the money.
  local function reputationRewardsOf(originalRewards)
    local reputationRewards = {}
    for rewardKey, rewardValue in pairs(originalRewards) do
      if rewardKey:endswith("Reputation") then
        reputationRewards[rewardKey] = rewardValue
      end
    end
    return reputationRewards
  end

  -- The damage row: excessive damage loses the whole reward, slight damage part of it, none pays a small bonus.
  local function partsDamageBreakdown(driving, brokenPartsThreshold, origMoney, reputationRewards)
    local brokenPartsRelative = driving.brokenPartsRelative
    local partsBreakdown = {simpleBreakdownType="bonus"}
    local brokenPartsMultiplier = 1
    if brokenPartsRelative >= EXCESSIVE_DAMAGE_RATIO then
      brokenPartsMultiplier = 0
      partsBreakdown.damageLevel = "excessive"
      partsBreakdown.label = _tr("ui.career.delivery.breakdown.excessiveDamage")
      partsBreakdown.rewards = {money = -origMoney}
      for rewardKey, rewardValue in pairs(reputationRewards) do
        partsBreakdown.rewards[rewardKey] = -2 * rewardValue
      end
    elseif driving.brokenPartsNumber >= brokenPartsThreshold then
      brokenPartsMultiplier = 0.8 - 0.6*(brokenPartsRelative*4)
      partsBreakdown.damageLevel = "slight"
      partsBreakdown.label = _tr("ui.career.delivery.breakdown.slightDamage")
      partsBreakdown.rewards = {money = -(1-brokenPartsMultiplier)*origMoney}
      for rewardKey, rewardValue in pairs(reputationRewards) do
        partsBreakdown.rewards[rewardKey] = -(1-brokenPartsMultiplier) * rewardValue
      end
    else
      partsBreakdown.damageLevel = "none"
      partsBreakdown.label = _tr("ui.career.delivery.breakdown.noDamage")
      partsBreakdown.rewards = {money = math.ceil(origMoney*0.05)}
    end
    return partsBreakdown, brokenPartsMultiplier
  end

  local function detourBonusRewards(origMoney, reputationRewards)
    local rewards = {money=origMoney*0.15+10}
    for rewardKey, rewardValue in pairs(reputationRewards) do
      rewards[rewardKey] = math.ceil(rewardValue*0.125)
    end
    return rewards
  end

  -- Bonus rows for a straight drive and for an on-time delivery; only for an undamaged vehicle.
  local function addCompletionBonuses(breakdown, driving, origMoney, reputationRewards)
    if driving.distanceDriven > 0 then
      if driving.distanceDriven/driving.originalDistance < DETOUR_DISTANCE_RATIO then
        local rewards = detourBonusRewards(origMoney, reputationRewards)
        table.insert(breakdown, {label = _tr("ui.career.delivery.breakdown.noDetours"), rewards = rewards, simpleBreakdownType="bonus", })
      end
    end
    if driving.timeTaken < driving.expectedTime then
      local rewards = detourBonusRewards(origMoney, reputationRewards)
      table.insert(breakdown, {label = _tr("ui.career.delivery.breakdown.noDelays"), rewards = rewards, simpleBreakdownType="bonus",})
    end
  end

  -- Logistics XP the delivery earned, read from whichever key the offer's rewards carry.
  local function logisticsXpEarnedOf(originalRewards)
    local logisticsSkillXpEarned = tonumber(originalRewards["logistics-delivery"])
    if not logisticsSkillXpEarned then
      logisticsSkillXpEarned = tonumber(originalRewards["logistics-vehicleDelivery"]) or tonumber(originalRewards["logistics"]) or 0
    end
    return logisticsSkillXpEarned
  end

  -- Each loaner organization takes its cut, unless employment already pays it on shift.
  local function addLoanerOrganisationCuts(breakdown, taskData, originalRewards, loanerOrgReputationReward)
    for organizationId, _ in pairs(taskData.loanerOrganisations or {}) do
      local emp = overhaul_career_work_employment
      if not (emp and emp.usesEmploymentPayForOrg and emp.usesEmploymentPayForOrg(organizationId)) then
        local organization = overhaul_world_organizations.getOrganization(organizationId)
        local level = organization and organization.reputation and organization.reputation.level
        local levelInfo = level and organization.reputationLevels and organization.reputationLevels[level+2]
        local organizationCut = (levelInfo and levelInfo.loanerCut and levelInfo.loanerCut.value or 0.5)

        local organizationElement = {
          label = core_locales.contextTranslate("ui.career.delivery.breakdown.loanerOrganization", {cut = round(organizationCut * 100)}),
          rewards = {money = -organizationCut * originalRewards.money},
          simpleBreakdownType = "loaner",
        }
        organizationElement.rewards[organizationId.."Reputation"] = loanerOrgReputationReward

        table.insert(breakdown, organizationElement)
      end
    end
  end

  -- The precision-parking row, or nil when the vehicle has no drop-off spot or no score. Money, logistics XP, skill XP and reputation each scale from the score's flat and percent bonuses.
  local function precisionBreakdownFor(taskData, originalRewards, logisticsSkillXpEarned)
    if not taskData.dropOffPsPath then return nil end
    local targetParkingSpot = deliveryServices.generator.getParkingSpotByPath(taskData.dropOffPsPath)
    if not targetParkingSpot then return nil end
    local precisionData = deliveryServices.precisionParking.calculateVehiclePrecisionScore(taskData.vehId, targetParkingSpot)
    if not precisionData then return nil end
    local precisionBonus = deliveryServices.precisionParking.getPrecisionParkingBonus(precisionData)

    local precisionBreakdown = {
      label = core_locales.contextTranslate("ui.career.delivery.breakdown.precisionParking", {
        precisionLevel = _tr("ui.career.delivery.precisionLevel." .. precisionBonus.precisionLevel)
      }),
      rewards = {},
      simpleBreakdownType = (precisionBonus.moneyFlat >= 0 and precisionBonus.logisticsFlat >= 0) and "bonus" or "penalty",
      precisionData = precisionData
    }

    local moneyReward = precisionBonus.moneyFlat + (originalRewards.money * precisionBonus.moneyPercent)
    if moneyReward ~= 0 then
      precisionBreakdown.rewards.money = math.ceil(moneyReward)
    end

    local logisticsReward = precisionBonus.logisticsFlat + logisticsSkillXpEarned * precisionBonus.logisticsPercent
    if logisticsReward ~= 0 then
      precisionBreakdown.rewards["logistics-delivery"] = math.ceil(logisticsReward)
    end

    -- Skill XP follows the logistics XP, so both delivery keys count (same as logistics for vehicle delivery).
    local skillBaseReward = (originalRewards["logistics-delivery"] or 0) + (originalRewards["logistics-vehicleDelivery"] or 0)
    local skillReward = precisionBonus.skillFlat + skillBaseReward * precisionBonus.skillPercent
    if skillReward ~= 0 then
      precisionBreakdown.rewards["logistics-delivery"] = (precisionBreakdown.rewards["logistics-delivery"] or 0) + math.ceil(skillReward)
    end

    if taskData.offer and taskData.offer.organization then
      local reputationReward = precisionBonus.reputationFlat + (originalRewards[taskData.offer.organization.."Reputation"] or 0) * precisionBonus.reputationPercent
      if reputationReward ~= 0 then
        precisionBreakdown.rewards[taskData.offer.organization.."Reputation"] = math.ceil(reputationReward)
      end
    end
    return precisionBreakdown
  end

  local function getRewardsWithBreakdown(taskData)
    local originalRewards = deepcopy(taskData.offer.rewards)
    local breakdown = {}
    local driving = readDrivingFacts(taskData)
    local brokenPartsThreshold = overhaul_career_market_valueCalculator.getBrokenPartsThreshold()
    local origMoney = originalRewards.money
    local reputationRewards = reputationRewardsOf(originalRewards)

    local partsBreakdown, brokenPartsMultiplier = partsDamageBreakdown(driving, brokenPartsThreshold, origMoney, reputationRewards)
    table.insert(breakdown, partsBreakdown)
    if brokenPartsMultiplier == 1 then
      addCompletionBonuses(breakdown, driving, origMoney, reputationRewards)
    end

    local logisticsSkillXpEarned = logisticsXpEarnedOf(originalRewards)
    local loanerOrgReputationReward = round(math.max(0, logisticsSkillXpEarned))
    addLoanerOrganisationCuts(breakdown, taskData, originalRewards, loanerOrgReputationReward)

    local precisionBreakdown = precisionBreakdownFor(taskData, originalRewards, logisticsSkillXpEarned)
    if precisionBreakdown then
      table.insert(breakdown, precisionBreakdown)
    end

    local adjustedRewards = deepcopy(originalRewards)
    for _, bd in ipairs(breakdown) do
      for key, amount in pairs(bd.rewards) do
        adjustedRewards[key] = (adjustedRewards[key] or 0) + amount
      end
    end
    return originalRewards, breakdown, adjustedRewards
  end

  -- Vehicle summaries -----------------------------------------------------------------------------

  local function getVehicleDataWithRewardsSummary(psPath)
    local vehicleRewardData = {}
    for _, taskData in ipairs(taskState.vehicleTasks) do
      local activeTask = taskData.tasks[taskData.activeTaskIndex]
      if activeTask.type == "confirmDropOff" then
        if not psPath or activeTask.destination.psPath == psPath then
          local formatted = deliveryServices.cargoScreen.formatAcceptedOfferForUI(taskData.offer)
          formatted.finished = false
          formatted._taskData = taskData
          table.insert(vehicleRewardData, formatted)
        end
      end
    end
    return vehicleRewardData
  end

  local function makeGatherVehicleDataSteps(vehicleRewardData)
    local sequence = {}
    for _, formatted in ipairs(vehicleRewardData) do
      local taskData = formatted._taskData
      if not taskData then goto continue end
      local veh = getObjectByID(taskData.vehId)
      if not veh then
        formatted.finished = true
        formatted._taskData = nil
        goto continue
      end
      table.insert(sequence, deliveryServices.step.makeStepReturnTrueFunction(function(s)
        if not s.sentCommand then
          s.sentCommand = true
          core_vehicleBridge.requestValue(veh, function(res)
            local partConditions = res.result
            if tableSize(partConditions) > 0 then
              taskData.brokenPartsNumber = overhaul_career_market_valueCalculator.getNumberOfBrokenParts(partConditions)
              taskData.partsNumber = tableSize(partConditions)
            end
            s.brokenPartsRequested = true
          end, 'getPartConditions')
        end
        return s.brokenPartsRequested or false
      end))
      table.insert(sequence, deliveryServices.step.makeStepReturnTrueFunction(function(s)
        if not s.sentCommand then
          s.sentCommand = true
          local vehData = core_vehicle_manager.getVehicleData(taskData.vehId)
          core_vehicleBridge.requestValue(veh, function(res)
            s.odometerComplete = true
            local mainPartName = "/" .. vehData.config.mainPartName
            local part = res.result[mainPartName]
            if part then
              taskData.offer.endingOdometer = part.odometer
            else
              taskData.offer.endingOdometer = -1
            end
          end, 'getPartConditions')
        end
        return s.odometerComplete or false
      end))
      table.insert(sequence, deliveryServices.step.makeStepReturnTrueFunction(function()
        formatted.originalRewards, formatted.breakdown, formatted.adjustedRewards = getRewardsWithBreakdown(taskData)
        formatted.finished = true
        formatted._taskData = nil
        return true
      end))
      ::continue::
    end
    return sequence
  end

  local function canDropOffCargoAtPsPath(psPath)
    local vehsClose, trailersClose = 0,0
    for _, taskData in ipairs(taskState.vehicleTasks) do
      local activeTask = taskData.tasks[taskData.activeTaskIndex]
      if activeTask.type == "confirmDropOff" and psPath == activeTask.destination.psPath then
        if taskData.offer.data.type == "vehicle" then vehsClose = vehsClose + 1 end
        if taskData.offer.data.type == "trailer" then trailersClose = trailersClose +1 end
      end
    end
    return vehsClose, trailersClose
  end
  local function makeFinishTasksSteps(affectedOffers)
    local sequence = {}
    for _, taskData in ipairs(affectedOffers) do
      local activeTask = taskData.tasks[taskData.activeTaskIndex]
      if activeTask.type ~= "confirmDropOff" then goto continue end
      local veh = getObjectByID(taskData.vehId)
      if not veh then
        taskData.logisticsPending = true
        goto continue
      end
      table.insert(sequence, deliveryServices.step.makeStepReturnTrueFunction(function(s)
        if not s.sentCommand then
          s.sentCommand = true
          core_vehicleBridge.requestValue(veh, function(res)
            local partConditions = res.result
            if tableSize(partConditions) > 0 then
              taskData.brokenPartsNumber = overhaul_career_market_valueCalculator.getNumberOfBrokenParts(partConditions)
              taskData.partsNumber = tableSize(partConditions)
            end
            s.brokenPartsRequested = true
          end, 'getPartConditions')
        end
        return s.brokenPartsRequested or false
      end))
      table.insert(sequence, deliveryServices.step.makeStepReturnTrueFunction(function(s)
        if not s.sentCommand then
          s.sentCommand = true
          local vehData = core_vehicle_manager.getVehicleData(taskData.vehId)
          core_vehicleBridge.requestValue(veh, function(res)
            s.odometerComplete = true
            local mainPartName = "/" .. vehData.config.mainPartName
            local part = res.result[mainPartName]
            if part then
              taskData.offer.endingOdometer = part.odometer
            else
              taskData.offer.endingOdometer = -1
            end
          end, 'getPartConditions')
        end
        return s.odometerComplete or false
      end))
      table.insert(sequence, deliveryServices.step.makeStepReturnTrueFunction(function()
        taskData.originalRewards, taskData.breakdown, taskData.adjustedRewards = getRewardsWithBreakdown(taskData)
        taskData.finished = true
        return true
      end))
      ::continue::
    end
    return sequence
  end

  local function ejectPlayerFromTaskVehicle(vehId, walkPos)
    if not vehId then return end
    if be:getPlayerVehicleID(0) ~= vehId then return end
    gameplay_walk.setWalkingMode(true, walkPos, nil, true)
  end

  local function deleteTaskVehicle(vehId, inventoryId)
    local inventory = overhaul_career_garage_inventory
    local id = inventoryId or (inventory and vehId and inventory.getInventoryIdFromVehicleId(vehId))
    local info = id and inventory.getVehicle(id)
    -- Task cleanup owns temporary delivery loans, never an existing player or company vehicle attached to the task. Keep its scene object as well.
    local record = issued.forVehicle(info) or {}
    if info and (not record.isDelivery or info.owned) then return end
    if not vehId and not info then return end
    if vehId and vehId >= 0 then
      ejectPlayerFromTaskVehicle(vehId)
      if be:getPlayerVehicleID(0) == vehId then return end
    end
    local veh = vehId and vehId >= 0 and scenetree.findObjectById(vehId)
    if info then
      inventory.removeVehicle(id, true)
      return
    end
    if veh then veh:delete() end
  end

  -- Completion and cleanup ------------------------------------------------------------------------

  local function processFinished(taskData)
    if taskData.finished then
      taskState.taskDataRemoveThisFrame = true

      local dropSpot = taskData.dropOffPsPath and deliveryServices.generator.getParkingSpotByPath(taskData.dropOffPsPath)
      local psPos = dropSpot and dropSpot.pos or nil
      local _ = nil
      local unicycleId = nil
      if be:getPlayerVehicleID(0) == taskData.vehId then
        _, unicycleId = gameplay_walk.setWalkingMode(true, psPos, nil, true)
      end
      deleteTaskVehicle(taskData.vehId,
        taskData.logisticsPending and taskData.offer and taskData.offer.vehicle
          and taskData.offer.vehicle.inventoryId or nil)

      local unicycle = scenetree.findObjectById(unicycleId)
      if unicycle then
        spawn.safeTeleport(unicycle, psPos)
      end

      callbacks.clearVehicleTasklistEntry(taskData)

      taskData.remove = true
      taskData.processFinishedComplete = true
      deliveryServices.progress.confirmDropOffCheckComplete()
    end
  end

  local function showMessageJob(job)
    local message = job.args[1]
    local category = job.args[2]
    local icon = job.args[3]
    job.sleep(1)
    guihooks.trigger('Message', {clear = nil, ttl = 10, msg = message, category = category, icon = icon})
  end

  local function getFineForAbandon(taskData)
    local fine = {money=-(taskData.offer.rewards.money or 0) * deliveryServices.general.getDeliveryAbandonPenaltyFactor()}
    if taskData.offer.organization then
      fine[taskData.offer.organization .. "Reputation"] = overhaul_career_progression_reputation.getValueForEvent("discardDeliveryVehicle")
    end
    return fine
  end
  local function processGiveBack(taskData)
    if taskData.giveBack then
      if overhaul_career_logistics_broker then overhaul_career_logistics_broker.onBrokerVehicleAbandoned(taskData.offer) end
      taskState.taskDataRemoveThisFrame = true
      ejectPlayerFromTaskVehicle(taskData.vehId)
      deleteTaskVehicle(taskData.vehId)
      callbacks.clearVehicleTasklistEntry(taskData)

      taskData.remove = true
      if not taskData.undeliverable then
        local fine = abandonFine(taskData)
        overhaul_career_economy_playerAttributes.addAttributes(fine, require("overhaul/lib/finance/metadata").tag({
          tags = {"gameplay", "delivery", "fine"},
          label = {
            txt = "ui.career.attributeLog.abandonedDeliveryPenaltyFor",
            context = { deliveryName = taskData.offer.name },
          },
        }, "fine"))

        local messageContext = {
          deliveryName = _tr(taskData.offer.name),
          penalty = string.format("%0.2f", -fine.money)
        }
        local messageKey = "ui.career.delivery.notification.abandoned"
        if taskData.offer.organization then
          messageKey = "ui.career.delivery.notification.abandonedWithReputation"
          messageContext.reputation = -fine[taskData.offer.organization .. "Reputation"]
        end
        local message = core_locales.contextTranslate(messageKey, messageContext)
        core_jobsystem.create(showMessageJob, nil, message, "delivery", "local_shipping")
      end
    end
  end

  local function navigateToNextTask()
    return callbacks.navigateToActiveTasks()
  end

  return {
    canDropOffCargoAtPsPath = canDropOffCargoAtPsPath,
    deleteTaskVehicle = deleteTaskVehicle,
    ejectPlayerFromTaskVehicle = ejectPlayerFromTaskVehicle,
    getFineForAbandon = getFineForAbandon,
    getVehicleDataWithRewardsSummary = getVehicleDataWithRewardsSummary,
    makeFinishTasksSteps = makeFinishTasksSteps,
    makeGatherVehicleDataSteps = makeGatherVehicleDataSteps,
    navigateToNextTask = navigateToNextTask,
    processFinished = processFinished,
    processGiveBack = processGiveBack,
    bindInputs = function(bindings)
      callbacks.clearVehicleTasklistEntry = assert(type(bindings.clearVehicleTasklistEntry) == 'function' and bindings.clearVehicleTasklistEntry, 'rewards.clearVehicleTasklistEntry callback required')
      callbacks.navigateToActiveTasks = assert(type(bindings.navigateToActiveTasks) == 'function' and bindings.navigateToActiveTasks, 'rewards.navigateToActiveTasks callback required')
    end,
  }
end

return part
