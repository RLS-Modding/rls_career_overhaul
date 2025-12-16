-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
M.dependencies = {"util_stepHandler"}
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dTasklist, dTutorial, dPrecisionParking
local step
M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dProgress = career_modules_delivery_progress
  dTasklist = career_modules_delivery_tasklist
  dTutorial = career_modules_delivery_tutorial
  dPrecisionParking = career_modules_delivery_precisionParking
  step = util_stepHandler
end

local vehicleTasks = {}
local taskThatChangedThisFrame

-- setup for data
local function expandTasks(offerTask, offer)
  local tasks = {}
  if offer.task.type == "trailerDropOff" then
    tasks = {
      {
        type = "coupleTrailer",
      }, {
        type = "bringToDestination",
        destination = offerTask.destination,
        backOn = "unCouple",
      --}, {
--        type = "putIntoParkingSpot",
  --      destination = offerTask.destination,
    --    forwardOn = "uncouple",
      }, {
        type = "confirmDropOff",
        destination = offerTask.dropOff,
      }
    }
  elseif offer.task.type == "vehicleDropOff" then
    tasks = {
      {
        type = "enterVehicle",
      }, {
        type = "bringToDestination",
        destination = offerTask.destination,
        backOn = "exitVehicle",
      }, {
        type = "confirmDropOff",
        destination = offerTask.dropOff,
      }
    }
  end
  return tasks
end

local function navigateToTask(task)
  local activeTaskStep = task.tasks[task.activeTaskIndex]
  if activeTaskStep.destination then
    local destinationPos = dGenerator.getParkingSpotByPath(activeTaskStep.destination.psPath).pos
    core_groundMarkers.setPath(destinationPos, {clearPathOnReachingTarget = false})
  elseif activeTaskStep.type == "enterVehicle" or activeTaskStep.type == "coupleTrailer" then
    local veh = getObjectByID(task.vehId)
    if veh then
      core_groundMarkers.setPath(veh:getPosition(), {clearPathOnReachingTarget = false})
    end
  end
end

local function addVehicleTask(vehId, offer)
  log("I","","addVehicleTask")
  local taskData = {
    vehId = vehId,
    offer = offer,
    tasks = expandTasks(offer.task, offer),
    activeTaskIndex = 1,
    startedTimestamp = dGeneral.time(),
  }
  table.insert(vehicleTasks, taskData)
  dTasklist.sendCargoToTasklist()
  navigateToTask(taskData)
end
M.addVehicleTask = addVehicleTask


-- checking task completeness

--[[
local function onCouplerAttached(objId1, objId2, nodeId, obj2nodeId)
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.vehId == objId1 or taskData.vehId == objId2 then
      local activeTask = taskData.tasks[taskData.activeTaskIndex]
      if activeTask.type == "coupleTrailer" then
        -- forward -> bringToDestination
        activeTask.coupled = true
      end
      if activeTask.type == "putIntoParkingSpot" then
        activeTask.uncoupled = false
      end
    end
  end
end

local function onCouplerDetached(objId1, objId2, nodeId, obj2nodeId)
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.vehId == objId1 or taskData.vehId == objId2 then
      local activeTask = taskData.tasks[taskData.activeTaskIndex]
      if activeTask.type == "bringToDestination" then
        -- back to -> coupleTrailer
        activeTask.uncoupled = true
      end
      if activeTask.type == "putIntoParkingSpot" then
        activeTask.uncoupled = true
      end
    end
  end
end
M.onCouplerAttached = onCouplerAttached
M.onCouplerDetached = onCouplerDetached
]]

local bringToDestinationThreshold = 20 * 20
local function processActiveTask(taskData)
  local taskIndexBefore = taskData.activeTaskIndex
  local activeTask = taskData.tasks[taskData.activeTaskIndex]
  if activeTask.type == "coupleTrailer" then
    -- check if coupled to trailer, go forward if so
    if core_trailerRespawn.getAttachedNonTrailer(taskData.vehId) == be:getPlayerVehicleID(0) then
      taskData.activeTaskIndex = taskData.activeTaskIndex + 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
  end

  if activeTask.type == "enterVehicle" then
    -- check if coupled to trailer, go forward if so
    if be:getPlayerVehicleID(0) == taskData.vehId then
      taskData.activeTaskIndex = taskData.activeTaskIndex + 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
  end

  if activeTask.type == "bringToDestination" then
    -- check if uncoupled, go back if so
    if activeTask.backOn == "uncouple" and (core_trailerRespawn.getAttachedNonTrailer(taskData.vehId) ~= be:getPlayerVehicleID(0)) then
      activeTask.uncoupled = nil
      taskData.activeTaskIndex = taskData.activeTaskIndex - 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
    if activeTask.backOn == "exitVehicle" and be:getPlayerVehicleID(0) ~= taskData.vehId then
      taskData.activeTaskIndex = taskData.activeTaskIndex - 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
    -- check if close enough to destination
    local trailerVeh = scenetree.findObjectById(taskData.vehId)
    local trailerPos = trailerVeh:getPosition()
    local destinationPos = dGenerator.getLocationCoordinates(activeTask.destination)
    if (trailerPos - destinationPos):squaredLength() <= bringToDestinationThreshold then
      taskData.activeTaskIndex = taskData.activeTaskIndex + 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
  end
  if activeTask.type == "putIntoParkingSpot" then
    -- check if parked in spot and uncoupled
    local trailerVeh = scenetree.findObjectById(taskData.vehId)
    local destinationPs = dGenerator.getParkingSpotByPath(activeTask.destination.psPath)
    local valid, res = destinationPs:checkParking(taskData.vehId)
    simpleDebugText3d(valid and "Valid" or "Invalid", destinationPs.pos + vec3(0,0,2), 0.25, valid and ColorF(0,1,0,0.25) or ColorF(1,0,0,0.25))
    destinationPs:drawDebug()
    if valid then
      if activeTask.forwardOn == "unCouple" and (core_trailerRespawn.getAttachedNonTrailer(taskData.vehId) ~= be:getPlayerVehicleID(0)) then
        taskData.activeTaskIndex = taskData.activeTaskIndex + 1
        dTasklist.updateTasklistForOfferId(taskData.offer.id)
      end
      if activeTask.forwardOn == "exitVehicle" and be:getPlayerVehicleID(0) ~= taskData.vehId then
        taskData.activeTaskIndex = taskData.activeTaskIndex + 1
        dTasklist.updateTasklistForOfferId(taskData.offer.id)
      end
    end

    -- check if too far away
    local trailerPos = trailerVeh:getPosition()
    local destinationPos = dGenerator.getLocationCoordinates(activeTask.destination)

    if (trailerPos - destinationPos):squaredLength() >= bringToDestinationThreshold*1.5 then
      taskData.activeTaskIndex = taskData.activeTaskIndex - 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
  end
  if activeTask.type == "confirmDropOff" then

  end

  if taskIndexBefore ~= taskData.activeTaskIndex then
    taskThatChangedThisFrame = taskData
  end
end

local function onTrailerAttached(objId1, objId2)
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.vehId then
      taskData.loanerOrganisations = taskData.loanerOrganisations or {}
      tableMerge(taskData.loanerOrganisations, career_modules_loanerVehicles.getLoaningOrgsOfVehicle(taskData.vehId))
    end
  end
end

local function getRewardsWithBreakdown(taskData)
  local originalRewards = deepcopy(taskData.offer.rewards)
  local breakdown = {}

  log("I","","Finished Vehicle: " .. taskData.vehId)
  local brokenPartsRelative = taskData.brokenPartsNumber / taskData.partsNumber
  log("I","",string.format("Broken Parts: %0.1f%% (%d / %d)", brokenPartsRelative*100, taskData.brokenPartsNumber, taskData.partsNumber))
  local distanceDriven = (taskData.offer.endingOdometer - taskData.offer.startingOdometer)
  if taskData.offer.startingOdometer == -1 or taskData.offer.endingOdometer == -1 then
    distanceDriven = 0
  end
  log("I","",string.format("Driven Distance: %0.3fkm (%0.1f%% of allowed %0.3fkm)", distanceDriven/1000, 100*distanceDriven/taskData.offer.data.originalDistance, 1.2*taskData.offer.data.originalDistance/1000))
  local timeTaken = dGeneral.time() - taskData.startedTimestamp
  local expectedTime = (taskData.offer.data.originalDistance/12 + 30 )
  log("I","",string.format("Time Taken: %0.1f seconds (expected: %0.1fs)", timeTaken, expectedTime))


  local brokenPartsThreshold = career_modules_valueCalculator.getBrokenPartsThreshold()

  local origMoney = originalRewards.money
  local reputationRewards = {}
  for rewardKey, rewardValue in pairs(originalRewards) do
    if rewardKey:endswith("Reputation") then
      reputationRewards[rewardKey] = rewardValue
    end
  end

  local partsBreakdown = {simpleBreakdownType="bonus"}
  local brokenPartsMultipler = 1
  if brokenPartsRelative >= 0.25 then
    brokenPartsMultipler = 0
    partsBreakdown.label = "Excessive Damage"
    partsBreakdown.rewards = {money = -origMoney}
    for rewardKey, rewardValue in pairs(reputationRewards) do
      partsBreakdown.rewards[rewardKey] = -2 * rewardValue
    end
  elseif taskData.brokenPartsNumber >= brokenPartsThreshold then
    brokenPartsMultipler = 0.8 - 0.6*(brokenPartsRelative*4)
    partsBreakdown.label = "Slight Damage"
    partsBreakdown.rewards = {money = -(1-brokenPartsMultipler)*origMoney}
    for rewardKey, rewardValue in pairs(reputationRewards) do
      partsBreakdown.rewards[rewardKey] = -(1-brokenPartsMultipler) * rewardValue
    end
  else
    partsBreakdown.label = "No Damage"
    partsBreakdown.rewards = {money = math.ceil(origMoney*0.05)}
  end

  table.insert(breakdown, partsBreakdown)

  if brokenPartsMultipler == 1 then
    if distanceDriven > 0 then
      if distanceDriven/taskData.offer.data.originalDistance < 1.2 then
        local rewards = {money=origMoney*0.15+10}
        for rewardKey, rewardValue in pairs(reputationRewards) do
          rewards[rewardKey] = math.ceil(rewardValue*0.125)
        end
        table.insert(breakdown, {label = "No Detours", rewards = rewards, simpleBreakdownType="bonus", })
      end
    end
    if timeTaken < expectedTime then
      local rewards = {money=origMoney*0.15+10}
      for rewardKey, rewardValue in pairs(reputationRewards) do
        rewards[rewardKey] = math.ceil(rewardValue*0.125)
      end
      table.insert(breakdown, {label = "No Delays", rewards = rewards, simpleBreakdownType="bonus",})
    end
  end

  for organizationId, _ in pairs(taskData.loanerOrganisations or {}) do
    local organization = freeroam_organizations.getOrganization(organizationId)
    local level = organization.reputation.level
    local organizationCut = (organization.reputationLevels[level+2].loanerCut and organization.reputationLevels[level+2].loanerCut.value or 0.5)

    local organizationElement = {
      label = string.format("Loaner Organization (%d%% cut)", round(organizationCut * 100)),
      rewards = {money = -organizationCut * originalRewards.money},
      simpleBreakdownType = "loaner",
    }
    organizationElement.rewards[organizationId.."Reputation"] = 5 + round(taskData.offer.data.originalDistance/1000)

    table.insert(breakdown, organizationElement)
  end

  local branchMultiplier = career_branches.getLevelRewardMultiplier("logistics")
  if branchMultiplier > 1 then
    local level = career_branches.getBranchLevel("logistics")
    table.insert(breakdown, {
      label = "Level " .. level .. " Multiplier",
      rewards = {money = originalRewards.money * branchMultiplier - originalRewards.money},
      simpleBreakdownType = "branch",
    })
  end

  -- Calculate precision parking and add to breakdown
  if taskData.dropOffPsPath then
    local targetParkingSpot = dGenerator.getParkingSpotByPath(taskData.dropOffPsPath)
    if targetParkingSpot then
      local precisionData = dPrecisionParking.calculateVehiclePrecisionScore(taskData.vehId, targetParkingSpot)
      if precisionData then
        local precisionBonus = dPrecisionParking.getPrecisionParkingBonus(precisionData)

        -- Add precision parking breakdown entry
        local precisionBreakdown = {
          label = "Precision Parking (" .. precisionBonus.precisionLevel:gsub("^%l", string.upper) .. ")",
          rewards = {},
          simpleBreakdownType = (precisionBonus.moneyFlat >= 0 and precisionBonus.logisticsFlat >= 0) and "bonus" or "penalty",
          precisionData = precisionData
        }

        -- Calculate money reward
        local moneyReward = precisionBonus.moneyFlat + (originalRewards.money * precisionBonus.moneyPercent)
        if moneyReward ~= 0 then
          precisionBreakdown.rewards.money = math.ceil(moneyReward)
        end

        -- Calculate logistics XP reward
        local logisticsReward = precisionBonus.logisticsFlat + (originalRewards["logistics"] or 0) * precisionBonus.logisticsPercent
        if logisticsReward ~= 0 then
          precisionBreakdown.rewards["logistics"] = math.ceil(logisticsReward)
        end

        -- Calculate skill XP reward (same as logistics for vehicle delivery)
        local skillReward = precisionBonus.skillFlat + (originalRewards["logistics-vehicleDelivery"] or 0) * precisionBonus.skillPercent
        if skillReward ~= 0 then
          precisionBreakdown.rewards["logistics-vehicleDelivery"] = (precisionBreakdown.rewards["logistics-vehicleDelivery"] or 0) + math.ceil(skillReward)
        end

        -- Calculate reputation reward
        if taskData.offer and taskData.offer.organization then
          local reputationReward = precisionBonus.reputationFlat + (originalRewards[taskData.offer.organization.."Reputation"] or 0) * precisionBonus.reputationPercent
          if reputationReward ~= 0 then
            precisionBreakdown.rewards[taskData.offer.organization.."Reputation"] = math.ceil(reputationReward)
          end
        end

        table.insert(breakdown, precisionBreakdown)
      end
    end
  end

  local adjustedRewards = deepcopy(originalRewards)
  for _, bd in ipairs(breakdown) do
    for key, amount in pairs(bd.rewards) do
      adjustedRewards[key] = (adjustedRewards[key] or 0) + amount
    end
  end
  return originalRewards, breakdown, adjustedRewards
end

local function getVehicleDataWithRewardsSummary(psPath)
  local vehicleRewardData = {}
  for _, taskData in ipairs(vehicleTasks) do
    local activeTask = taskData.tasks[taskData.activeTaskIndex]
    if activeTask.type == "confirmDropOff" then
      if not psPath or activeTask.destination.psPath == psPath then
        local formatted = dCargoScreen.formatAcceptedOfferForUI(taskData.offer)
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
    table.insert(sequence, step.makeStepReturnTrueFunction(function(s)
      if not s.sentCommand then
        s.sentCommand = true
        core_vehicleBridge.requestValue(veh, function(res)
          local partConditions = res.result
          if tableSize(partConditions) > 0 then
            taskData.brokenPartsNumber = career_modules_valueCalculator.getNumberOfBrokenParts(partConditions)
            taskData.partsNumber = tableSize(partConditions)
          end
          s.brokenPartsRequested = true
        end, 'getPartConditions')
      end
      return s.brokenPartsRequested or false
    end))
    table.insert(sequence, step.makeStepReturnTrueFunction(function(s)
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
    table.insert(sequence, step.makeStepReturnTrueFunction(function()
      formatted.originalRewards, formatted.breakdown, formatted.adjustedRewards = getRewardsWithBreakdown(taskData)
      formatted.finished = true
      formatted._taskData = nil
      return true
    end))
    ::continue::
  end
  return sequence
end

M.getVehicleDataWithRewardsSummary = getVehicleDataWithRewardsSummary
M.makeGatherVehicleDataSteps = makeGatherVehicleDataSteps

local function canDropOffCargoAtPsPath(psPath)
  local vehsClose, trailersClose = 0,0
  for _, taskData in ipairs(vehicleTasks) do
    local activeTask = taskData.tasks[taskData.activeTaskIndex]
    if activeTask.type == "confirmDropOff" and psPath == activeTask.destination.psPath then
      if taskData.offer.data.type == "vehicle" then vehsClose = vehsClose + 1 end
      if taskData.offer.data.type == "trailer" then trailersClose = trailersClose +1 end
    end
  end
  return vehsClose, trailersClose
end
M.canDropOffCargoAtPsPath = canDropOffCargoAtPsPath


local function makeFinishTasksSteps(affectedOffers)
  local sequence = {}
  for _, taskData in ipairs(affectedOffers) do
    local activeTask = taskData.tasks[taskData.activeTaskIndex]
    if activeTask.type ~= "confirmDropOff" then goto continue end
    local veh = getObjectByID(taskData.vehId)
    if not veh then
      taskData.finished = true
      goto continue
    end
    table.insert(sequence, step.makeStepReturnTrueFunction(function(s)
      if not s.sentCommand then
        s.sentCommand = true
        core_vehicleBridge.requestValue(veh, function(res)
          local partConditions = res.result
          if tableSize(partConditions) > 0 then
            taskData.brokenPartsNumber = career_modules_valueCalculator.getNumberOfBrokenParts(partConditions)
            taskData.partsNumber = tableSize(partConditions)
          end
          s.brokenPartsRequested = true
        end, 'getPartConditions')
      end
      return s.brokenPartsRequested or false
    end))
    table.insert(sequence, step.makeStepReturnTrueFunction(function(s)
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
    table.insert(sequence, step.makeStepReturnTrueFunction(function()
      taskData.originalRewards, taskData.breakdown, taskData.adjustedRewards = getRewardsWithBreakdown(taskData)
      taskData.finished = true
      return true
    end))
    ::continue::
  end
  return sequence
end

M.finishTasks = function(offerIds)
  local affectedOffers = {}
  local offersById = tableValuesAsLookupDict(offerIds)
  for _, taskData in ipairs(vehicleTasks) do
    if offersById[taskData.offer.id] then
      table.insert(affectedOffers, taskData)
      taskData.finished = false
      local activeTask = taskData.tasks[taskData.activeTaskIndex]
      if activeTask.type == "confirmDropOff" then
        taskData.dropOffPsPath = activeTask.destination.psPath
      end
    end
  end
  local sequence = makeFinishTasksSteps(affectedOffers)
  if #sequence > 0 then
    step.startStepSequence(sequence, function()
      dProgress.confirmDropOffCheckComplete()
    end)
  end
  return affectedOffers
end

local taskDataRemoveThisFrame = false
local function processFinished(taskData)
  if taskData.finished then
    taskDataRemoveThisFrame = true

    local psPos = dGenerator.getParkingSpotByPath(taskData.dropOffPsPath).pos
    local _, unicycleId
    if be:getPlayerVehicleID(0) == taskData.vehId then
      _, unicycleId = gameplay_walk.setWalkingMode(true, psPos)
    end
    local veh = scenetree.findObjectById(taskData.vehId)
    if veh then veh:delete() end

    local unicycle = scenetree.findObjectById(unicycleId)
    if unicycle then
      spawn.safeTeleport(unicycle, psPos)
    end

    dTasklist.clearTasklistForOfferId(taskData.offer.id)

    taskData.remove = true
    taskData.processFinishedComplete = true
    dProgress.confirmDropOffCheckComplete()
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
  local fine = {money=-(taskData.offer.rewards.money or 0) * dGeneral.getDeliveryAbandonPenaltyFactor()}
  if taskData.offer.organization then
    fine[taskData.offer.organization .. "Reputation"] = career_modules_reputation.getValueForEvent("discardDeliveryVehicle")
  end
  return fine
end
M.getFineForAbandon = getFineForAbandon

local function processGiveBack(taskData)
  if taskData.giveBack then
    taskDataRemoveThisFrame = true
    if be:getPlayerVehicleID(0) == taskData.vehId then
      gameplay_walk.setWalkingMode(true)
    end
    local veh = scenetree.findObjectById(taskData.vehId)
    if veh then veh:delete() end
    dTasklist.clearTasklistForOfferId(taskData.offer.id)

    local fine = M.getFineForAbandon(taskData)

    career_modules_playerAttributes.addAttributes(fine, {tags={"gameplay", "delivery","fine"}, label="Abandoned Delivery Penalty for " .. taskData.offer.name})
    taskData.remove = true

    local message = string.format("Delivery %s abandoned. \n %0.2f$ penalty. " .. (taskData.offer.organization and "\n%d reputation lost." or ""), taskData.offer.name, -fine.money, taskData.offer.organization and -fine[taskData.offer.organization .. "Reputation"] or 0)
    core_jobsystem.create(showMessageJob, nil, message, "delivery", "local_shipping")
  end
end

local function navigateToNextTask()
  if vehicleTasks[#vehicleTasks] then
    navigateToTask(vehicleTasks[#vehicleTasks])
  end
end

local toDeleteActiveTrailerIndexes = {}
local function onUpdate(dtReal, dtSim, dtRaw)
  taskThatChangedThisFrame = nil
  for _, taskData in ipairs(vehicleTasks) do
    if not taskData.remove then
      processActiveTask(taskData)
    end
  end
  for _, taskData in ipairs(vehicleTasks) do
    if not taskData.remove then
      processFinished(taskData)
    end
  end
  for _, taskData in ipairs(vehicleTasks) do
    if not taskData.remove then
      processGiveBack(taskData)
    end
  end

  local idsToRemove = {}
  if taskDataRemoveThisFrame then
    for id, taskData in ipairs(vehicleTasks) do
      if taskData.remove then
        table.insert(idsToRemove, id)
      end
    end
    -- remove from the back to avoid ids moving
    for _, id in ipairs(arrayReverse(idsToRemove)) do
      local taskToBeRemoved = vehicleTasks[id]
      table.remove(vehicleTasks, id)
    end

    dGeneral.checkExitDeliveryMode()
  end

  if taskThatChangedThisFrame then
    navigateToTask(taskThatChangedThisFrame)
  elseif not tableIsEmpty(idsToRemove) and not tableIsEmpty(vehicleTasks) then
    -- Navigate to the next task if one has been removed
    navigateToTask(vehicleTasks[#vehicleTasks])
  end

  taskDataRemoveThisFrame = false
end
M.onUpdate = onUpdate


local function getTargetDestinationsForActiveTasks()
  local ret = {}
  for id, taskData in ipairs(vehicleTasks) do
    for _, task in ipairs(taskData.tasks) do
      if task.destination then
        table.insert(ret, task.destination)
      end
    end
  end
  return ret
end
M.getTargetDestinationsForActiveTasks = getTargetDestinationsForActiveTasks


local function isVehicleDeliveryVehicle(vehId)
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.vehId == vehId then
      return true
    end
  end
  return false
end
M.isVehicleDeliveryVehicle = isVehicleDeliveryVehicle

local function giveBackDeliveryVehicle(vehId)
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.vehId == vehId then
      taskData.giveBack = true
      return
    end
  end
end
M.giveBackDeliveryVehicle = giveBackDeliveryVehicle

local function getVehicleTasks()
  return vehicleTasks
end
M.getVehicleTasks = getVehicleTasks

local function getFineForAbandonAllVehicleTasks()
  local fine = {}
  for _, taskData in ipairs(vehicleTasks) do
    for attKey, amount in pairs(M.getFineForAbandon(taskData)) do
      fine[attKey] = (fine[attKey] or 0) + amount
    end
  end
  return fine
end
M.getFineForAbandonAllVehicleTasks = getFineForAbandonAllVehicleTasks

local function abandonAllVehicleTasks()
  for _, taskData in ipairs(vehicleTasks) do
    if be:getPlayerVehicleID(0) == taskData.vehId then
      gameplay_walk.setWalkingMode(true)
    end
    local veh = scenetree.findObjectById(taskData.vehId)
    if veh then veh:delete() end
  end
  vehicleTasks = {}
end
M.abandonAllVehicleTasks = abandonAllVehicleTasks

local function getVehicleTaskForOffer(offer)
  for _, task in ipairs(vehicleTasks) do
    if task.offer.id == offer.id then
      return task
    end
  end
  return nil
end
M.getVehicleTaskForOffer = getVehicleTaskForOffer

-- DEBUG part
local im = ui_imgui
M.debugOrder = 12
M.debugName = "Delivery > Trailer Tasks"
local function drawDebugMenu()
  if im.Begin("Trailer Tasks Debug") then
    im.Text(dumps(vehicleTasks))

    im.End()
  end
end

M.drawDebugMenu = drawDebugMenu
M.onTrailerAttached = onTrailerAttached
M.navigateToNextTask = navigateToNextTask

return M