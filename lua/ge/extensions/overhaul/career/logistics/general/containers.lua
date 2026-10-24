-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Part of the Overhaul fork of stock lua/ge/extensions/career/modules/delivery/general.lua.

-- Nearby cargo containers and weight updates. Map: vehicle bridge, nearby scan, weights, part API; general owns runtime state.

local part = {}

-- A vehicle that does not answer the cargo API (a dyno hub config, for example) is not polled again until it respawns or this many seconds pass.
local NO_CARGO_API_RETRY_SEC = 60
-- A vehicle whose cab is this close to the player counts as nearby for a scan with no ids.
local CAB_SCAN_RADIUS_SQUARED_M = 40 * 40
-- A container whose node is off the vehicle's cluster is nearby below this distance, lost above it.
local NEARBY_CONTAINER_DISTANCE_M = 10

-- Vehicle names and cargo bridge ------------------------------------------------------------------

local function getVehicleName(vehId)
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
  local niceVehicleName = inventoryId and overhaul_career_garage_inventory.getVehicleNiceNameTranslated(inventoryId)
  if type(niceVehicleName) == "string" and niceVehicleName ~= "" then
    return niceVehicleName
  end
  return core_locales.contextTranslate("ui.career.delivery.general.vehicleFallback", {id = vehId})
end

local function sortByVehIdAndContainerId(a, b)
  if a.vehId == b.vehId then
    return a.containerId < b.containerId
  end
  return a.vehId < b.vehId
end

local function isPassengerOnly(cargoTypes)
  if not cargoTypes then return false end
  local hasPassenger = false
  for _, cargoType in ipairs(cargoTypes) do
    if cargoType ~= "passenger" then return false end
    hasPassenger = true
  end
  return hasPassenger
end

local function isUnicycle(veh)
  return veh and veh.getJBeamFilename and veh:getJBeamFilename() == "unicycle"
end

local function getCargoBridgeVehicle(vehId)
  local veh = scenetree.findObjectById(tonumber(vehId) or vehId)
  -- Remembered cargo IDs can outlive their vehicle or resolve to a scene prop. requestValue requires a vehicle Lua queue; unlike executeAction, it has no guard.
  return veh and veh.queueLuaCommand and veh or nil
end

-- Returns the container list from a bridge response. An "unknown system" failure starts the retry wait.
local function getCargoContainerListFromBridge(state, response, vehId)
  if type(response) == "table" and type(response[1]) == "table" then
    return response[1]
  end
  if type(response) == "table" and type(response.failReason) == "string"
      and response.failReason:find("unknown system", 1, true) then
    state.noCargoApiUntil[vehId] = os.clock() + NO_CARGO_API_RETRY_SEC
  end

  if not state.warnedCargoResponses[vehId] then
    state.warnedCargoResponses[vehId] = true
    local reason = type(response) == "table" and response.failReason or nil
    log("W", "", string.format(
      "Ignoring invalid cargo-container response from vehicle %s%s.",
      tostring(vehId),
      reason and (": " .. tostring(reason)) or ""
    ))
  end
  return {}
end

local function isUsableContainer(state, vehId, container)
  if type(container) == "table" and container.id ~= nil then return true end
  local warningKey = "container:" .. tostring(vehId)
  if not state.warnedCargoResponses[warningKey] then
    state.warnedCargoResponses[warningKey] = true
    log("W", "", string.format("Skipping malformed cargo container from vehicle %s: %s", tostring(vehId), dumps(container)))
  end
  return false
end

-- Vehicles to ask for their containers. Each gets a -1 placeholder until its answer arrives.
-- Nearby scan -------------------------------------------------------------------------------------

local function findScanVehicles(state, vehicleIds, cargoContainersByVehicleId)
  local playerPos = getPlayerVehicle(0)
  playerPos = playerPos and playerPos:getPosition() or core_camera.getPosition()
  local footprintSet = {}
  local footprint = {}
  overhaul_vehicles_playerVehicles.fillInteractionVehicleIds(footprint)
  for i = 1, #footprint do
    footprintSet[footprint[i]] = true
  end
  local nearbyVehicles = {}
  local refNodeClusterIdByVehId = {}
  local now = os.clock()
  for vehId, veh in activeVehiclesIterator() do
    if state.noCargoApiUntil[vehId] and now >= state.noCargoApiUntil[vehId] then state.noCargoApiUntil[vehId] = nil end
    if veh:getJBeamFilename() ~= "unicycle" and veh.playerUsable ~= false and not state.noCargoApiUntil[vehId] then
      local isNearCab = playerPos and (playerPos - veh:getPosition()):squaredLength() < CAB_SCAN_RADIUS_SQUARED_M
      if (vehicleIds and vehicleIds[vehId]) or (not vehicleIds and (footprintSet[vehId] or isNearCab)) then
        cargoContainersByVehicleId[vehId] = -1
        nearbyVehicles[vehId] = veh
        refNodeClusterIdByVehId[vehId] = veh:getNodeClusterId(veh:getRefNodeId())
      end
    end
  end
  return nearbyVehicles, refNodeClusterIdByVehId
end

local function containerAttachmentStatus(veh, containerData)
  if not containerData.clusterId or containerData.refNodeClusterId == containerData.clusterId then
    return "attached"
  end
  local distanceToVehicleMeters = (containerData.position - veh:getPosition()):length()
  if distanceToVehicleMeters < NEARBY_CONTAINER_DISTANCE_M then
    return "nearby"
  end
  return "lost"
end

-- Slots used by parcels in the container, and by moves that are pending into it.
local function countContainerSlots(inputs, containerData)
  local parcelManager = inputs.services.parcelManager
  containerData.rawCargo = parcelManager.getAllCargoForLocation(containerData.location)
  containerData.transientCargo = parcelManager.getTransientMovesForTargetLocationWithCargo(containerData.location)

  for _, cargo in ipairs(containerData.rawCargo) do
    containerData.usedCargoSlots = containerData.usedCargoSlots + cargo.slots
    containerData.freeCargoSlots = containerData.freeCargoSlots - cargo.slots
  end

  for _, cargo in ipairs(containerData.transientCargo) do
    containerData.usedCargoSlots = containerData.usedCargoSlots + cargo.slots
    containerData.transientCargoSlots = containerData.transientCargoSlots + cargo.slots
    containerData.freeCargoSlots = containerData.freeCargoSlots - cargo.slots
  end
end

local function buildContainerData(inputs, vehId, veh, container, refNodeClusterId, cargoTypes)
  local capacity = tonumber(container.capacity) or 0
  local vehName = getVehicleName(vehId)
  local containerData = {
    vehId = vehId,
    containerId = container.id,
    location = {type = "vehicle", vehId = veh:getID(), containerId = container.id},
    vehName = vehName,
    name = container.name or "Unnamed Container",
    moveToLabel = vehName .. " " .. (container.name or "Unnamed Container"),
    cargoTypesLookup = tableValuesAsLookupDict(cargoTypes),
    cargoTypesString = table.concat(cargoTypes, ", "),
    totalCargoSlots = capacity,
    usedCargoSlots = 0,
    transientCargoSlots = 0,
    freeCargoSlots = capacity,
    refNodeClusterId = refNodeClusterId,
    clusterId = container.nodeId and veh:getNodeClusterId(container.nodeId),
    position = (container.nodeId and veh:getNodePosition(container.nodeId) or vec3(0, 0, 0)) + veh:getPosition(),
  }
  containerData.attachmentStatus = containerAttachmentStatus(veh, containerData)
  countContainerSlots(inputs, containerData)
  return containerData
end

-- The containers of one vehicle that carry something other than passengers.
local function collectVehicleContainers(inputs, vehId, veh, refNodeClusterId, response)
  local containers = {}
  for _, container in ipairs(getCargoContainerListFromBridge(inputs.state, response, vehId)) do
    if isUsableContainer(inputs.state, vehId, container) then
      local cargoTypes = type(container.cargoTypes) == "table" and container.cargoTypes or {}
      if not isPassengerOnly(cargoTypes) then
        containers[#containers + 1] = buildContainerData(inputs, vehId, veh, container, refNodeClusterId, cargoTypes)
      end
    end
  end
  return containers
end

local function anyVehicleStillPending(cargoContainersByVehicleId)
  for _, value in pairs(cargoContainersByVehicleId) do
    if value == -1 then return true end
  end
  return false
end

local function finishNearbyScan(inputs, cargoContainersByVehicleId, vehicleIds, callback, generation)
  local cargoContainers = {}
  for _, list in pairs(cargoContainersByVehicleId) do
    for _, containerData in ipairs(list) do
      table.insert(cargoContainers, containerData)
    end
  end
  table.sort(cargoContainers, sortByVehIdAndContainerId)
  if not vehicleIds and inputs.state.nearbyScanGeneration == generation then
    inputs.state.mostRecentCargoContainerData = cargoContainers
  end
  callback(cargoContainers)
end

local function getNearbyVehicleCargoContainers(inputs, callback, vehicleIds)
  local lifecycle = inputs.state.nearbyScanLifecycle
  local generation
  if not vehicleIds then
    generation = (inputs.state.nearbyScanGeneration or 0) + 1
    inputs.state.nearbyScanGeneration = generation
  end
  if not core_vehicleBridge then
    callback({})
    return
  end
  local cargoContainersByVehicleId = {}
  local nearbyVehicles, refNodeClusterIdByVehId = findScanVehicles(inputs.state, vehicleIds, cargoContainersByVehicleId)
  for vehId, veh in pairs(nearbyVehicles) do
    core_vehicleBridge.requestValue(veh, function(response)
      -- Obsolete full scans must not dereference vehicles from the previous map.
      if not vehicleIds and inputs.state.nearbyScanLifecycle ~= lifecycle then
        cargoContainersByVehicleId[vehId] = {}
      else
        cargoContainersByVehicleId[vehId] = collectVehicleContainers(inputs, vehId, veh, refNodeClusterIdByVehId[vehId], response)
      end
      if anyVehicleStillPending(cargoContainersByVehicleId) then return end
      finishNearbyScan(inputs, cargoContainersByVehicleId, vehicleIds, callback, generation)
    end, "overhaulGetCargoContainers")
  end
  if not next(nearbyVehicles) then
    finishNearbyScan(inputs, cargoContainersByVehicleId, vehicleIds, callback, generation)
  end
end

-- Unfreezes the vehicles whose cargo was loaded, then tells the prompt and listeners the wait is over.
-- Loading freeze and delays -----------------------------------------------------------------------

local function releaseCargoLoadingFreeze(state, delaysByVehicleId)
  for vehId in pairs(delaysByVehicleId) do
    local veh = getCargoBridgeVehicle(vehId)
    if veh then core_vehicleBridge.executeAction(veh, 'setFreeze', false) end
  end
  overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt()
  state.defaultWeightUpdateActive = false
  extensions.hook("onOverhaulDeliveryCargoLoadingFinished", delaysByVehicleId)
end

local function defaultDelayCallback(state, delaysByVehicleId)
  state.defaultWeightUpdateActive = true
  extensions.hook("onOverhaulDeliveryCargoLoadingStarted", delaysByVehicleId)
  local maxDelaySeconds = 0
  for _, delay in pairs(delaysByVehicleId) do
    maxDelaySeconds = math.max(delay, maxDelaySeconds)
  end
  if maxDelaySeconds > 0 then
    maxDelaySeconds = math.max(maxDelaySeconds, 1)
    -- Only one wait sequence runs at a time; a newer one cancels this wait.
    core_jobsystem.create(function(job)
      job.sleep(maxDelaySeconds + 0.5)
      releaseCargoLoadingFreeze(state, delaysByVehicleId)
    end)
    guihooks.trigger("OpenSimpleDelayPopup", {timer = maxDelaySeconds, heading = _tr("ui.career.delivery.general.loadingCargo")})
  else
    releaseCargoLoadingFreeze(state, delaysByVehicleId)
  end
  log("I", "", string.format("%0.2fs delay after adjusting weights for cargo.", maxDelaySeconds))
end

-- Weight updates ----------------------------------------------------------------------------------

local function rememberCargoWeightVehicle(state, vehId)
  vehId = tonumber(vehId) or vehId
  if vehId then
    state.rememberedWeightVehicleIds[vehId] = true
  end
end

local function rememberCurrentCargoWeightVehicles(inputs)
  for _, cargo in ipairs(inputs.services.parcelManager.getAllCargoInVehicles() or {}) do
    if cargo.location and cargo.location.vehId then
      rememberCargoWeightVehicle(inputs.state, cargo.location.vehId)
    end
  end
end

-- Every vehicle that may hold cargo: the ones on the map, remembered ones, and those named by cargo or containers.
local function collectCargoWeightVehicleIds(inputs)
  local vehIds = {}
  for vehId, veh in activeVehiclesIterator() do
    if veh and not isUnicycle(veh) and veh.playerUsable ~= false then
      vehIds[vehId] = true
    end
  end
  for vehId in pairs(inputs.state.rememberedWeightVehicleIds) do
    vehIds[vehId] = true
  end
  for _, cargo in ipairs(inputs.services.parcelManager.getAllCargoInVehicles() or {}) do
    if cargo.location and cargo.location.vehId then
      vehIds[cargo.location.vehId] = true
    end
  end
  for _, container in ipairs(inputs.state.mostRecentCargoContainerData or {}) do
    if container.vehId then
      vehIds[container.vehId] = true
    end
  end
  return vehIds
end

local function addCargoLoadsToVehicles(inputs, updatePerVehicle)
  for _, cargo in ipairs(inputs.services.parcelManager.getAllCargoInVehicles()) do
    local vehId = cargo.location and cargo.location.vehId
    vehId = tonumber(vehId) or vehId
    if vehId and updatePerVehicle[vehId] then
      local containerId = cargo.location.containerId
      updatePerVehicle[vehId][containerId] = updatePerVehicle[vehId][containerId] or {
        volume = 0,
        density = 1,
        containerId = containerId,
      }
      if not cargo.weight then
        log("W", "", "No weight on cargo? " .. dumps(cargo.name))
        dump(cargo)
      end
      require('overhaul/lib/logistics/cargoSemantics').addContainerLoad(updatePerVehicle[vehId][containerId], cargo)
    end
  end
end

local function sendContainerLoads(updatePerVehicle)
  for vehId in pairs(updatePerVehicle) do
    local veh = getCargoBridgeVehicle(vehId)
    if veh then
      core_vehicleBridge.executeAction(veh, "overhaulSetCargoContainers", updatePerVehicle[vehId] or {}, "updateDelivery")
      core_vehicleBridge.executeAction(veh, 'setFreeze', true)

      if next(updatePerVehicle[vehId]) then
        for _, con in pairs(updatePerVehicle[vehId]) do
          log("I", "", string.format("Container %d => volume %0.1f | density: %0.1f", con.containerId, con.volume or 0, con.density or 1))
        end
      else
        log("I", "", string.format("Vehicle %s => emptied all cargo containers", tostring(vehId)))
      end
    end
  end
end

-- Every vehicle that can be reached gets a -1 until its reach time arrives.
local function placeholderDelays(updatePerVehicle)
  local delays = {}
  for vehId in pairs(updatePerVehicle) do
    if getCargoBridgeVehicle(vehId) then
      delays[vehId] = -1
    end
  end
  return delays
end

-- Asks each vehicle how long its slowest non-passenger container needs; the callback runs once all have answered.
local function requestLoadingDelays(state, loadingDelaysByVehicleId, delayCallback)
  local hasCalledDelayCallback = false
  local function finishDelayCallback()
    if hasCalledDelayCallback then return end
    for _, delay in pairs(loadingDelaysByVehicleId) do
      if delay == -1 then return end
    end
    hasCalledDelayCallback = true
    delayCallback(loadingDelaysByVehicleId)
  end

  for vehId in pairs(loadingDelaysByVehicleId) do
    local veh = getCargoBridgeVehicle(vehId)
    if veh then
      core_vehicleBridge.requestValue(veh, function(response)
        local maxLoadingDelaySeconds = 0
        for _, container in ipairs(getCargoContainerListFromBridge(state, response, vehId)) do
          if not isPassengerOnly(container.cargoTypes) then
            maxLoadingDelaySeconds = math.max(maxLoadingDelaySeconds, tonumber(container.reachTargetTimeRemaining) or 0)
          end
        end
        loadingDelaysByVehicleId[vehId] = maxLoadingDelaySeconds
        finishDelayCallback()
      end, "overhaulGetCargoContainers")
    else
      loadingDelaysByVehicleId[vehId] = nil
    end
  end
  finishDelayCallback()
end

local function updateContainerWeights(inputs, delayCallback)
  local state = inputs.state
  if not state.updateWeightsScheduled then
    return
  end
  delayCallback = delayCallback or function(delays) defaultDelayCallback(state, delays) end
  state.updateWeightsScheduled = false
  log("I", "", "updateContainerWeights...")

  local updatePerVehicle = {}
  for vehId in pairs(collectCargoWeightVehicleIds(inputs)) do
    vehId = tonumber(vehId) or vehId
    local veh = getCargoBridgeVehicle(vehId)
    if veh and not isUnicycle(veh) then
      updatePerVehicle[vehId] = {}
    end
  end
  state.rememberedWeightVehicleIds = {}
  addCargoLoadsToVehicles(inputs, updatePerVehicle)
  sendContainerLoads(updatePerVehicle)
  requestLoadingDelays(state, placeholderDelays(updatePerVehicle), delayCallback)
end

-- Cache, warning and weight-update fields live in the runtime record owned by general.
-- Part API ----------------------------------------------------------------------------------------

function part.new(inputs)
  assert(inputs.state and inputs.services, "logistics general containers need state and services")
  return {
    getVehicleName = getVehicleName,
    getNearbyVehicleCargoContainers = function(callback, vehicleIds)
      getNearbyVehicleCargoContainers(inputs, callback, vehicleIds)
    end,
    clearNoCargoApiRetry = function(vehId)
      inputs.state.noCargoApiUntil[vehId] = nil
    end,
    rememberCargoWeightVehicle = function(vehId)
      rememberCargoWeightVehicle(inputs.state, vehId)
    end,
    rememberCurrentCargoWeightVehicles = function()
      rememberCurrentCargoWeightVehicles(inputs)
    end,
    updateContainerWeights = function(delayCallback)
      updateContainerWeights(inputs, delayCallback)
    end,
  }
end

return part
