-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/delivery/vehicleTasks.lua (BeamNG 0.40).

-- Owns accepted vehicle-delivery tasks, their lifecycle and drop-off completion.
-- Private parts in vehicleTasks/ handle hauling updates and reward calculation.
-- Start with dependency binding and task setup, then cancellation and completion operations.
-- Public queries and engine hooks connect those tasks to the cargo screen and progress.

local M = {}

-- State ---------------------------------------------------------------------------------------

M.dependencies = {"overhaul_shell_stepHandler"}
-- Sibling extensions and the step handler, set in onCareerActivated (shared by the vehicle task files).
local deliveryServices = {
  parcelManager = nil,
  cargoScreen = nil,
  general = nil,
  generator = nil,
  progress = nil,
  tasklist = nil,
  precisionParking = nil,
  step = nil,
}
-- Active vehicle tasks and per-frame task flags shared by the vehicle task files.
local taskState = {
  vehicleTasks = {},
  taskThatChangedThisFrame = nil,
  lastHaulerVehId = nil,
  taskDataRemoveThisFrame = false,
}
local parts = {}

-- Binding -------------------------------------------------------------------------------------

M.onCareerActivated = function()
  deliveryServices.parcelManager = overhaul_career_logistics_parcelManager
  deliveryServices.cargoScreen = overhaul_career_logistics_cargoScreen
  deliveryServices.general = overhaul_career_logistics_general
  deliveryServices.generator = overhaul_career_logistics_generator
  deliveryServices.progress = overhaul_career_logistics_progress
  deliveryServices.tasklist = overhaul_career_logistics_tasklist
  deliveryServices.precisionParking = overhaul_career_logistics_precisionParking
  deliveryServices.step = overhaul_shell_stepHandler
end

local tasklistRefreshPending = false

-- Task setup and navigation -------------------------------------------------------------------

-- Keep this in sync with delivery/tasklist.lua. Vehicle task entries use a
-- stable UI id, while the task-list module's offer-id lookup can be stale when
-- a coupled dolly is deleted during its completion callback.
local function clearVehicleTasklistEntry(taskData)
  if not taskData or not taskData.offer then return end
  if deliveryServices.tasklist then
    deliveryServices.tasklist.clearTasklistForOfferId(taskData.offer.id)
  end
  guihooks.trigger("DiscardTasklistItem", "trailer" .. tostring(taskData.offer.id))
  tasklistRefreshPending = true
end

local function offerDestination(offer)
  if not offer then return nil end
  local task = offer.task
  return (task and (task.dropOff or task.destination))
    or offer.destination
    or (offer.locations and offer.locations[2])
end

local function employmentShiftDestination()
  local emp = overhaul_career_work_employment
  if emp and emp.getShiftDestLocation then
    return emp.getShiftDestLocation()
  end
  return nil
end

local function resolveVehicleDestination(taskData, prefer)
  local candidates = {
    prefer,
    taskData and taskData.tasks and taskData.tasks[2] and taskData.tasks[2].destination,
    taskData and taskData.tasks and taskData.tasks[3] and taskData.tasks[3].destination,
    offerDestination(taskData and taskData.offer),
    employmentShiftDestination(),
  }
  for _, dest in ipairs(candidates) do
    if dest and dest.psPath and deliveryServices.generator and deliveryServices.generator.getParkingSpotByPath(dest.psPath) then
      return dest
    end
  end
  for _, dest in ipairs(candidates) do
    if dest and (dest.psPath or dest.facId) then
      return dest
    end
  end
  return nil
end

local function isEmploymentJockeyShift()
  local emp = overhaul_career_work_employment
  return emp and emp.isJockeyShift() or false
end

local function isBundleFlatbedPending()
  local emp = overhaul_career_work_employment
  return emp and emp.isBundleFlatbedPending() or false
end

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
        backOn = "uncouple",
      }, {
        type = "confirmDropOff",
        destination = offerTask.dropOff or offerTask.destination,
      }
    }
  elseif offer.task.type == "vehicleDropOff" then
    local dest = offerTask.dropOff or offerTask.destination or offer.destination
    dest = resolveVehicleDestination({ offer = offer }, dest)
    tasks = {
      {
        type = "enterVehicle",
      }, {
        type = "bringToDestination",
        destination = dest,
        backOn = "exitVehicle",
      }, {
        type = "confirmDropOff",
        destination = dest,
      }
    }
  end
  return tasks
end

-- Like cargo multi-drop: every active vehicle/trailer task destination is on the route
-- at once (nearest first). Avoids last-accepted-wins nav hiding the other yards.
local function collectActiveNavigationTargets()
  local targets = {}
  local seen = {}
  local jockeyShift = isEmploymentJockeyShift()
  local skipVehicleDests = isBundleFlatbedPending()
  for _, taskData in ipairs(taskState.vehicleTasks) do
    if taskData.remove then goto continue end
    if skipVehicleDests then goto continue end
    local activeTaskStep = taskData.tasks[taskData.activeTaskIndex]
    if not activeTaskStep then goto continue end

    if activeTaskStep.type == "enterVehicle" or activeTaskStep.type == "coupleTrailer" then
      local key = "veh-" .. tostring(taskData.vehId)
      if not seen[key] then
        local veh = getObjectByID(taskData.vehId)
        if veh then
          seen[key] = true
          targets[#targets + 1] = { key = key, pos = veh:getPosition() }
        end
      end
    else
      local dest = activeTaskStep.destination
      if (not dest or not dest.psPath) and jockeyShift then
        dest = resolveVehicleDestination(taskData, dest)
      end
      if dest and dest.psPath then
        local key = dest.psPath
        if not seen[key] then
          local ps = deliveryServices.generator.getParkingSpotByPath(key)
          if ps and ps.pos then
            seen[key] = true
            targets[#targets + 1] = { key = key, pos = ps.pos }
          end
        end
      end
    end
    ::continue::
  end
  return targets
end

local function navigateToActiveTasks()
  local targets = collectActiveNavigationTargets()
  if #targets == 0 then
    local emp = overhaul_career_work_employment
    if emp and emp.isBundleFlatbedPending() then
      if emp.reassertBundleFlatbedRoute then
        return emp.reassertBundleFlatbedRoute() and true or false
      end
      return false
    end
    if emp and emp.isOnShift() then
      return false
    end
    core_groundMarkers.setPath(nil)
    return false
  end

  local playerVeh = getPlayerVehicle(0)
  local playerPos = playerVeh and playerVeh:getPosition() or nil
  if playerPos then
    table.sort(targets, function(a, b)
      return (a.pos - playerPos):squaredLength() < (b.pos - playerPos):squaredLength()
    end)
  end

  if #targets == 1 then
    core_groundMarkers.setPath(targets[1].pos, {clearPathOnReachingTarget = false})
    return true
  end

  local path = {}
  for i, target in ipairs(targets) do
    path[i] = target.pos
  end
  core_groundMarkers.setPath(path, {clearPathOnReachingTarget = false})
  return true
end

local function addVehicleTask(vehId, offer)
  for _, existing in ipairs(taskState.vehicleTasks) do
    if not existing.remove and existing.offer.id == offer.id then return end
  end
  local inventory = overhaul_career_garage_inventory
  local employment = overhaul_career_work_employment
  if inventory then
    local id = offer.vehicle.inventoryId or inventory.getInventoryIdFromVehicleId(vehId)
    local isNew = not id
    if not id and vehId and vehId > 0 then
      id = inventory.addVehicle(vehId, nil, {owned = false, skipPartConditionInit = true})
    end
    local info = id and inventory.getVehicle(id)
    if info and (offer.brokerId or isNew) then
      info.loanType = "delivery"
      info.brokerJobId = offer.brokerId
      info.owningOrganization = offer.organization
      info.takesNoInventorySpace = true
    end
    offer.vehicle.inventoryId = id
    local info = id and inventory.getVehicle(id)
    if info then info.logisticsInUse = true end
  end
  log("I","","addVehicleTask")
  local taskData = {
    vehId = vehId,
    offer = offer,
    tasks = expandTasks(offer.task, offer),
    activeTaskIndex = 1,
    startedTimestamp = deliveryServices.general.time(),
  }
  if offer.logisticsTask then
    for k, value in pairs(offer.logisticsTask) do taskData[k] = deepcopy(value) end
    offer.logisticsTask = nil
  end
  taskData.logisticsPending = not (vehId and vehId > 0 and getObjectByID(vehId)) or nil
  table.insert(taskState.vehicleTasks, taskData)
  deliveryServices.tasklist = overhaul_career_logistics_tasklist or deliveryServices.tasklist
  if deliveryServices.tasklist then
    deliveryServices.tasklist.sendCargoToTasklist()
  else
    tasklistRefreshPending = true
  end
  navigateToActiveTasks()
  if deliveryServices.general then
    deliveryServices.general.requestDeliveryPoiRefresh(true)
  elseif gameplay_rawPois then
    gameplay_rawPois.clear()
  end
end
M.addVehicleTask = addVehicleTask

-- Loading another snapshot on the same map can retain this extension. Discard
-- its previous Broker scene tasks before restoring saved tasks, without issuing
-- payouts, abandonment fines, or deleting the newly loaded inventory records.
function M.clearBrokerTasksForLoad()
  for i=#taskState.vehicleTasks,1,-1 do
    local task=taskState.vehicleTasks[i]
    if task.offer.brokerId then
      clearVehicleTasklistEntry(task)
      local veh=getObjectByID(task.vehId)
      if veh then veh:delete() end
      table.remove(taskState.vehicleTasks,i)
    end
  end
end

function M.restoreBrokerTask(saved, vehId)
  for _, task in ipairs(taskState.vehicleTasks) do if task.offer.id == saved.offer.id then return end end
  taskState.vehicleTasks[#taskState.vehicleTasks+1] = {vehId=vehId, offer=saved.offer, tasks=deepcopy(saved.tasks),
    activeTaskIndex=saved.activeTaskIndex, startedTimestamp=saved.startedTimestamp}
  tasklistRefreshPending = true
end


function M.receiveHaulSurfaceDamage(id, requestId, broken)
  local cached = parts.hauling.haulSupport.topology[id]
  if not cached or cached.requestId ~= requestId then return end
  cached.broken = {}
  for _, triangle in ipairs(broken) do cached.broken[triangle] = true end
  cached.damageTime = parts.hauling.haulSupport.time
end




-- Completion ----------------------------------------------------------------------------------

M.finishTasks = function(offerIds, missingVehicleDropOff)
  local affectedOffers, fallbackOffers = {}, {}
  local offersById = tableValuesAsLookupDict(offerIds)
  for _, taskData in ipairs(taskState.vehicleTasks) do
    local activeTask = taskData.tasks and taskData.tasks[taskData.activeTaskIndex]
    local vehicleReady = not taskData.logisticsPending
      and taskData.vehId and getObjectByID(taskData.vehId)
    local destination = activeTask and activeTask.destination
      or (taskData.offer and (taskData.offer.destination
        or (taskData.offer.task and taskData.offer.task.destination)))
    local missingAtAssignedDropOff = missingVehicleDropOff and not vehicleReady
      and destination and destination.psPath == missingVehicleDropOff.psPath
      and (not destination.facId or destination.facId == missingVehicleDropOff.facId)
      and (activeTask.type == "confirmDropOff"
        or (activeTask.type == "bringToDestination" and (tonumber(taskData.activeTaskIndex) or 0) > 1))
      and overhaul_career_work_employment and overhaul_career_work_employment.isAssignedVehicleOffer
      and overhaul_career_work_employment.isAssignedVehicleOffer(taskData.offer)
    if offersById[taskData.offer.id] and not taskData.finished and not taskData.remove
        and (vehicleReady or missingAtAssignedDropOff) then
      if missingAtAssignedDropOff then
        taskData.finished = true
        taskData.dropOffPsPath = destination.psPath
        local rewards = deepcopy(taskData.offer.rewards or {})
        fallbackOffers[#fallbackOffers + 1] = {
          offer = taskData.offer,
          originalRewards = rewards,
          adjustedRewards = deepcopy(rewards),
          breakdown = {},
          finished = true,
        }
      else
        table.insert(affectedOffers, taskData)
        taskData.finished = false
        if activeTask.type == "confirmDropOff" then
          taskData.dropOffPsPath = activeTask.destination.psPath
        end
      end
    end
  end
  local sequence = parts.rewards.makeFinishTasksSteps(affectedOffers)
  for _, offer in ipairs(fallbackOffers) do
    affectedOffers[#affectedOffers + 1] = offer
  end
  if #sequence > 0 then
    deliveryServices.step.startStepSequence(sequence, function()
      deliveryServices.progress.confirmDropOffCheckComplete()
    end)
  else
    for _, taskData in ipairs(affectedOffers) do
      taskData.finished = true
    end
    deliveryServices.progress.confirmDropOffCheckComplete()
  end
  return affectedOffers
end


-- Per-frame update ----------------------------------------------------------------------------

-- Haul support pairs expire two sim seconds after their last use.
local function tickHaulSupport(dtSim)
  local support = parts.hauling.haulSupport
  support.time = support.time + (dtSim or 0)
  for key, state in pairs(support.pairs) do
    if support.time - state.used > 2 then support.pairs[key] = nil end
  end
end

-- Hauling, then rewards, then give-back: each stage runs over every live task before the next starts.
local function processLiveTasks(dtSim)
  for _, taskData in ipairs(taskState.vehicleTasks) do
    if not taskData.remove then
      parts.hauling.processActiveTask(taskData, dtSim)
    end
  end
  for _, taskData in ipairs(taskState.vehicleTasks) do
    if not taskData.remove then
      parts.rewards.processFinished(taskData)
    end
  end
  for _, taskData in ipairs(taskState.vehicleTasks) do
    if not taskData.remove then
      parts.rewards.processGiveBack(taskData)
    end
  end
end

-- Takes the removed tasks out of the list and returns their list positions, for the refresh below.
local function removeMarkedTasks()
  local idsToRemove = {}
  for id, taskData in ipairs(taskState.vehicleTasks) do
    if taskData.remove then
      table.insert(idsToRemove, id)
    end
  end
  -- remove from the back to avoid ids moving
  for _, id in ipairs(arrayReverse(idsToRemove)) do
    local taskToBeRemoved = taskState.vehicleTasks[id]
    table.remove(taskState.vehicleTasks, id)
    local transfer = overhaul_career_logistics_vehicleTransfer
    if transfer and transfer.onVehicleTaskRemoved and taskToBeRemoved then
      transfer.onVehicleTaskRemoved(taskToBeRemoved)
    end
  end

  deliveryServices.general.checkExitDeliveryMode()
  -- Rebuild only after the completed task is gone from vehicleTasks, so an
  -- asynchronous task-list refresh cannot re-add its stale dolly entry.
  if tasklistRefreshPending then
    deliveryServices.tasklist = overhaul_career_logistics_tasklist or deliveryServices.tasklist
    if deliveryServices.tasklist then
      deliveryServices.tasklist.sendCargoToTasklist()
      tasklistRefreshPending = false
    end
  end
  return idsToRemove
end

-- Navigation, HUD task lists and the drop-off markers follow the task list after a change.
local function refreshAfterTaskChange()
  navigateToActiveTasks()
  local emp = overhaul_career_work_employment
  if emp and emp.refreshHudTasklist and emp.ownsHudTasklist() then
    emp.refreshHudTasklist(true)
  elseif emp and emp.onVehicleTaskStepChanged then
    emp.onVehicleTaskStepChanged()
  end
  local transfer = overhaul_career_logistics_vehicleTransfer
  if transfer and transfer.isOnShift() then
    transfer.refreshHudTasklist(true)
  end
  -- Drop-off parking markers come from onGetRawPoiListForLevel → getTargetDestinations.
  -- Active step can change (enterVehicle → bringToDestination) without any other clear,
  -- so rebuild playmode POIs here; otherwise markers stay stale until big map open/close.
  if deliveryServices.general then
    deliveryServices.general.requestDeliveryPoiRefresh(true)
  elseif gameplay_rawPois then
    gameplay_rawPois.clear()
  end
  if overhaul_integration_services_markerInteraction then
    overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt()
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  tickHaulSupport(dtSim)
  deliveryServices.tasklist = overhaul_career_logistics_tasklist or deliveryServices.tasklist
  taskState.taskThatChangedThisFrame = nil
  processLiveTasks(dtSim)

  local idsToRemove = {}
  if taskState.taskDataRemoveThisFrame then
    idsToRemove = removeMarkedTasks()
  end
  if taskState.taskThatChangedThisFrame or not tableIsEmpty(idsToRemove) then
    refreshAfterTaskChange()
  end

  taskState.taskDataRemoveThisFrame = false
end
M.onUpdate = onUpdate


-- Queries -------------------------------------------------------------------------------------

local function getTargetDestinationsForActiveTasks()
  local ret = {}
  local seen = {}
  local jockeyShift = isEmploymentJockeyShift()
  local skipVehicleDests = isBundleFlatbedPending()
  for _, taskData in ipairs(taskState.vehicleTasks) do
    if taskData.remove then goto continue end
    if skipVehicleDests then goto continue end
    local activeIdx = taskData.activeTaskIndex or 1
    local activeTask = taskData.tasks[activeIdx]
    local dest = nil
    if activeTask and (activeTask.type == "enterVehicle" or activeTask.type == "coupleTrailer") then
      dest = nil
    elseif jockeyShift then
      dest = resolveVehicleDestination(taskData, activeTask and activeTask.destination)
    elseif activeTask and activeTask.destination and activeTask.destination.psPath then
      dest = activeTask.destination
    elseif activeTask and activeTask.type ~= "enterVehicle" and activeTask.type ~= "coupleTrailer" then
      for i = activeIdx + 1, #(taskData.tasks or {}) do
        local stepTask = taskData.tasks[i]
        if stepTask and stepTask.destination and stepTask.destination.psPath then
          dest = stepTask.destination
          break
        end
      end
    end
    if dest and dest.psPath and not seen[dest.psPath] then
      seen[dest.psPath] = true
      table.insert(ret, dest)
    end
    ::continue::
  end
  return ret
end
M.getTargetDestinationsForActiveTasks = getTargetDestinationsForActiveTasks

local function getPrimaryActiveVehicleTaskInfo()
  for _, taskData in ipairs(taskState.vehicleTasks) do
    if not taskData.remove then
      local step = taskData.tasks[taskData.activeTaskIndex]
      local playerId = be:getPlayerVehicleID(0)
      local inCargo = playerId and tonumber(playerId) == tonumber(taskData.vehId)
      return {
        vehId = taskData.vehId,
        offerId = taskData.offer and taskData.offer.id,
        stepType = step and step.type,
        inCargoVehicle = inCargo and true or false,
        haulAcquired = taskData.haulAcquired and true or false,
        destination = resolveVehicleDestination(taskData, step and step.destination),
      }
    end
  end
  return nil
end
M.getPrimaryActiveVehicleTaskInfo = getPrimaryActiveVehicleTaskInfo

function M.isCargoOnHaulerBed(cargoVehId, haulerVehId)
  return parts.hauling.haulSupport.isLoaded(cargoVehId, haulerVehId)
end

function M.getCargoCarrier(cargoVehId, carrierIds)
  local cargo = getObjectByID(cargoVehId)
  local pending = false
  for _, id in ipairs(carrierIds) do
    if id ~= cargoVehId and not parts.hauling.isActiveCargoTaskVehId(id) then
      local carrier = getObjectByID(id)
      if parts.hauling.memberCanBedCarry(carrier) then
        local supported, waiting = parts.hauling.cargoOnMemberBed(cargo, carrier)
        if supported then return id end
        pending = pending or waiting == true
      end
    end
  end
  return nil, pending
end

local function isVehicleDeliveryVehicle(vehId)
  for _, taskData in ipairs(taskState.vehicleTasks) do
    if taskData.vehId == vehId then
      return true
    end
  end
  return false
end
M.isVehicleDeliveryVehicle = isVehicleDeliveryVehicle

local function giveBackDeliveryVehicle(vehId)
  for _, taskData in ipairs(taskState.vehicleTasks) do
    if taskData.vehId == vehId then
      local employment = overhaul_career_work_employment
      if employment and employment.isAssignedVehicleOffer(taskData.offer) then
        ui_message('Abandon the company assignment from Employment so its held pay and equipment are settled together.', 8, 'warning')
        return false
      end
      taskData.giveBack = true
      return
    end
  end
end
M.giveBackDeliveryVehicle = giveBackDeliveryVehicle

function M.reportVehicleUndeliverable(vehId)
  for _, taskData in ipairs(taskState.vehicleTasks) do
    if taskData.vehId == vehId and not taskData.remove and not taskData.finished and not taskData.giveBack then
      taskData.undeliverable = true
      taskData.giveBack = true
      return true
    end
  end
  return false
end

function M.cancelUnmovedTransfer(offerId)
  local transfer = overhaul_career_logistics_vehicleTransfer
  if not (transfer and transfer.canCancelUnmovedOffer and transfer.canCancelUnmovedOffer(offerId)) then return false end
  for _, taskData in ipairs(taskState.vehicleTasks) do
    if taskData.offer.id == offerId and not taskData.remove and not taskData.finished and not taskData.giveBack then
      parts.rewards.ejectPlayerFromTaskVehicle(taskData.vehId)
      taskData.remove = true
      parts.rewards.deleteTaskVehicle(taskData.vehId)
      clearVehicleTasklistEntry(taskData)
      taskState.taskDataRemoveThisFrame = true
      return true
    end
  end
  return false
end

local function getVehicleTasks()
  return taskState.vehicleTasks
end
M.getVehicleTasks = getVehicleTasks

-- The recovery scan borrows these functions only for the current operation.
function M.onOverhaulRecoveryCargoCarriers(request)
  if request.carrierOf then return end
  request.carrierOf = M.getCargoCarrier
  request.readTasks = M.getVehicleTasks
end

function M.shelveOffMapTask(taskData)
  if not taskData or taskData.remove then return end
  taskData.remove = true
  taskState.taskDataRemoveThisFrame = true
  clearVehicleTasklistEntry(taskData)
end

function M.canReturnBrokerEquipment(vehId)
  parts.hauling.fillHaulerGroup(vehId)
  if #parts.hauling.haulGroupScratch>1 then return false,'Uncouple the equipment before returning it.' end
  local carrier=getObjectByID(vehId)
  for _,task in ipairs(taskState.vehicleTasks) do
    if not task.remove then
      local cargo = getObjectByID(task.vehId)
      if parts.hauling.cargoOnMemberBed(cargo,carrier,true) then
        return false,'Unload the carried vehicles before returning this equipment.'
      end
    end
  end
  return true
end

local function getFineForAbandonAllVehicleTasks(forSave)
  local fine = {}
  for _, taskData in ipairs(taskState.vehicleTasks) do
    if not (forSave and taskData.offer.brokerId and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(taskData.vehId)) then
    for attKey, amount in pairs(M.getFineForAbandon(taskData)) do
      fine[attKey] = (fine[attKey] or 0) + amount
    end
    end
  end
  return fine
end
M.getFineForAbandonAllVehicleTasks = getFineForAbandonAllVehicleTasks

local function abandonAllVehicleTasks()
  for _, taskData in ipairs(taskState.vehicleTasks) do
    taskData.remove = true
    if overhaul_career_logistics_broker then overhaul_career_logistics_broker.onBrokerVehicleAbandoned(taskData.offer) end
    parts.rewards.deleteTaskVehicle(taskData.vehId, taskData.offer.vehicle.inventoryId)
  end
  taskState.vehicleTasks = {}
  deliveryServices.general.checkExitDeliveryMode()
end
M.abandonAllVehicleTasks = abandonAllVehicleTasks

local function getVehicleTaskForOffer(offer)
  for _, task in ipairs(taskState.vehicleTasks) do
    if task.offer.id == offer.id then
      return task
    end
  end
  return nil
end
M.getVehicleTaskForOffer = getVehicleTaskForOffer

-- Parts -------------------------------------------------------------------------------------------

parts.hauling = require("overhaul/career/logistics/vehicleTasks/hauling").new({services = deliveryServices, state = taskState})
parts.rewards = require("overhaul/career/logistics/vehicleTasks/rewards").new({
  services = deliveryServices, state = taskState,
  abandonFine = function(...) return M.getFineForAbandon(...) end,
})
parts.hauling.bindInputs({
  isEmploymentJockeyShift = isEmploymentJockeyShift,
  navigateToActiveTasks = navigateToActiveTasks,
  resolveVehicleDestination = resolveVehicleDestination,
})
parts.rewards.bindInputs({clearVehicleTasklistEntry = clearVehicleTasklistEntry, navigateToActiveTasks = navigateToActiveTasks})

M.getVehicleDataWithRewardsSummary = parts.rewards.getVehicleDataWithRewardsSummary
M.makeGatherVehicleDataSteps = parts.rewards.makeGatherVehicleDataSteps
M.canDropOffCargoAtPsPath = parts.rewards.canDropOffCargoAtPsPath
M.getFineForAbandon = parts.rewards.getFineForAbandon
M.onTrailerAttached = parts.hauling.onTrailerAttached
M.onVehicleSwitched = parts.hauling.onVehicleSwitched
M.navigateToNextTask = parts.rewards.navigateToNextTask

-- Debug menu ----------------------------------------------------------------------------------

local im = ui_imgui
M.debugOrder = 12
M.debugName = "Delivery > Trailer Tasks"
local function drawDebugMenu()
  if im.Begin("Trailer Tasks Debug") then
    im.Text(dumps(taskState.vehicleTasks))

  end
  im.End()
end

M.drawDebugMenu = drawDebugMenu
M.onVehicleDestroyed = function(id)
  parts.hauling.haulSupport.invalidate(id)
end
M.onVehicleSpawned = function(id)
  parts.hauling.haulSupport.invalidate(id)
end
M.onVehicleResetted = function(id)
  parts.hauling.haulSupport.invalidate(id)
end
M.onClientEndMission = function()
  table.clear(parts.hauling.haulSupport.topology)
  table.clear(parts.hauling.haulSupport.pairs)
  taskState.lastHaulerVehId = nil
end

return M
