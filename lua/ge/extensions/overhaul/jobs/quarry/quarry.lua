-- Quarry contract flow, loading zones, truck state and UI callbacks.
-- Read state, parts, player actions, frame phases, lifecycle, save restore and game hooks.
local quarrySettings = require("overhaul/jobs/quarry/settings")

local M = {}
local levelData = require("overhaul/lib/world/levelData")

-- Config ----------------------------------------------------------------------------------------

local ZONE_STOCK_UPDATE_INTERVAL = 1
local IN_TRUCK_MIN_RATIO = 0.1 -- share of a prop that must be on the bed for it to count as loaded

-- State -------------------------------------------------------------------------------------------

local modules = {}
local parts = {}

local currentState
local stateHandlers
local compatibleZones = {}
local uiUpdateTimer = 0
local contractUpdateTimer = 0

local cachedPlayerVeh = nil
local cachedPlayerPos = nil
local playerCacheTimer = 0
local zoneStockUpdateTimer = 0

local loadedExtensions = {}

local loadedProfileName = nil
local loadJobSequence = 0

-- Save ownership --------------------------------------------------------------------------------

-- The owner can load before saving is available; each operation uses the current service.
local saveSystem = setmetatable({}, {__index = function(_, name)
  return overhaul_career_saveSystem and overhaul_career_saveSystem[name]
end})
local quarryPersistence = require('overhaul/lib/save/store').bind(saveSystem).feature('jobs.quarry', {
owner = 'overhaul_jobs_quarry_quarry', files = {'career/rls_career/loading.json'},
root = 'slot', phase = 'profile', required = true, writer = {pretty = true},
restore = function(context) return context.read() end,
})
-- Parts -------------------------------------------------------------------------------------------

parts.phoneState = require('overhaul/jobs/quarry/phoneState')(function()
    return modules.config, modules.contracts, modules.manager, modules.zones, cachedPlayerPos, compatibleZones, currentState
  end)

-- Guidance and zone swaps -----------------------------------------------------------------------

local function triggerPhoneState()
  local payload = parts.phoneState.getPhoneStateForUI()
  if payload then
    guihooks.trigger('updateQuarryState', payload)
  end
end

local function unloadSubModules()
  if require('overhaul/lib/shell/childExtensions').unload(loadedExtensions) == false then return false end
  loadedExtensions = {}
end

local function deliveryDestinationPosition()
  local jobs = modules.manager.jobObjects
  return jobs.deliveryDestination and vec3(jobs.deliveryDestination.pos)
    or (jobs.activeGroup and jobs.activeGroup.destination and vec3(jobs.activeGroup.destination.pos))
end

-- Swapping zones after the contract is already complete just ends the job.
local function endJobForCompletedContract()
  if modules.manager.jobObjects.truckID then
    local obj = be:getObjectByID(modules.manager.jobObjects.truckID)
    if obj then obj:delete() end
  end
  modules.manager.cleanupJob(true, modules.config.STATE_IDLE)
  currentState = modules.config.STATE_AT_QUARRY_DECIDE
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_End_Success')
  ui_message("Contract complete! Ready to finalize.", 6, "success")
end

-- A swap during delivery keeps what the truck carries, so the delivery is credited on arrival.
local function rememberSwapDelivery()
  local jobs = modules.manager.jobObjects
  if currentState ~= modules.config.STATE_DELIVERING or not jobs.truckID then return end
  local truck = be:getObjectByID(jobs.truckID)
  if not truck then return end
  local loadedPropIds = modules.manager.getLoadedPropIdsInTruck(IN_TRUCK_MIN_RATIO)
  if not (loadedPropIds and #loadedPropIds > 0) then return end
  jobs.zoneSwapLoadedPropIds = loadedPropIds
  local materialType = jobs.materialType
  local materialConfig = materialType and modules.config.materials and modules.config.materials[materialType]
  if materialConfig and materialConfig.unitType == "item" then
    jobs.deliveryBlocksStatus = modules.manager.getItemBlocksStatus()
    jobs.zoneSwapDeliveryBlocksStatus = jobs.deliveryBlocksStatus
  end
  jobs.zoneSwapDeliveredMass = jobs.lastDeliveredMass or jobs.currentLoadMass or 0
end

-- The truck keeps driving to the delivery destination while the player picks the new zone.
local function sendTruckToSwapDestination()
  local jobs = modules.manager.jobObjects
  local destinationPosition = jobs.truckID and deliveryDestinationPosition()
  if destinationPosition then
    modules.manager.driveTruckToPoint(jobs.truckID, destinationPosition)
    ui_message("Select new zone. Truck driving to destination...", 5, "info")
  else
    ui_message("Select new zone...", 5, "info")
  end
end

-- Starts a zone swap: the player chooses the new zone while the current delivery finishes.
local function beginZoneSwap()
  local jobs = modules.manager.jobObjects
  rememberSwapDelivery()
  if currentState ~= modules.config.STATE_DELIVERING then
    modules.manager.clearProps()
  else
    jobs.zoneSwapClearPropsOnArrival = true
  end
  currentState = modules.config.STATE_CHOOSING_ZONE
  jobs.zoneSwapPending = true
  jobs.zoneSwapTargetZone = nil
  jobs.zoneSwapTruckAtDestination = false
  sendTruckToSwapDestination()
  jobs.currentLoadMass = 0
  jobs.lastDeliveredMass = 0
  modules.manager.deliveryTimer = 0
  modules.manager.truckStoppedTimer = 0
  modules.manager.truckLastPosition = nil
  triggerPhoneState()
end

local function publishZoneSelection(selectedZone, notice)
  local targetPosition = modules.manager.getLoadingZoneTargetPos(selectedZone)
  if targetPosition then core_groundMarkers.setPath(targetPosition) end
  local cache = modules.zones.ensureGroupCache(selectedZone, modules.contracts.getCurrentGameHour)
  local displayName = cache and cache.name or selectedZone.siteTag or selectedZone.secondaryTag
  ui_message(string.format(notice, displayName), 5, "info")
  triggerPhoneState()
end

-- Player action callbacks -----------------------------------------------------------------------

local uiCallbacks = {
  onAcceptContract = function(index)
    if modules.contracts.ContractSystem.activeContract then return end
    local contract, zones = modules.contracts.acceptContract(index, modules.zones.getZonesByTypeName)
    if contract then
      if modules.zones and contract.materialTypeName then
        local compatibleZonesList = modules.zones.getZonesByTypeName(contract.materialTypeName)
        for _, zone in ipairs(compatibleZonesList) do
          local cache = modules.zones.ensureGroupCache(zone, modules.contracts.getCurrentGameHour)
          if cache then
            cache.spawnedPropCounts = {}
          end
        end
      end
      modules.manager.jobObjects.zoneSwapPending = false
      modules.manager.jobObjects.zoneSwapTargetZone = nil
      modules.manager.jobObjects.zoneSwapTruckAtDestination = false
      currentState = modules.config.STATE_CHOOSING_ZONE
      compatibleZones = zones
    end
  end,
  onDeclineAll = function()
    if modules.contracts.ContractSystem.activeContract then return end
    currentState = modules.config.STATE_IDLE
    modules.manager.jobOfferSuppressed = true
    triggerPhoneState()
    if overhaul_career_career.isActive() then
      overhaul_career_saveSystem.saveCurrent()
    end
  end,
  getCompatibleZones = function()
    if #compatibleZones == 0 and modules.contracts.ContractSystem.activeContract and modules.contracts.ContractSystem.activeContract.materialTypeName then
      compatibleZones = modules.zones.getZonesByTypeName(modules.contracts.ContractSystem.activeContract.materialTypeName)
    end
    return compatibleZones
  end,
  onSwapZone = function()
    local contract = modules.contracts.ContractSystem.activeContract
    if not (contract and contract.materialTypeName) then return end

    if modules.contracts.checkContractCompletion() then
      endJobForCompletedContract()
      return
    end

    compatibleZones = modules.zones.getZonesByTypeName(contract.materialTypeName)
    if #compatibleZones > 1 then
      beginZoneSwap()
    end
  end,
  onSelectZone = function(zoneIndex)
    if not zoneIndex or zoneIndex <= 0 then
      return
    end
    if #compatibleZones == 0 then
      local contract = modules.contracts.ContractSystem.activeContract
      if contract and contract.materialTypeName then
        compatibleZones = modules.zones.getZonesByTypeName(contract.materialTypeName) or {}
      end
    end
    if zoneIndex > #compatibleZones then
      return
    end
    local selectedZone = compatibleZones[zoneIndex]
    local contract = modules.contracts.ContractSystem.activeContract
    if contract and selectedZone then
      if modules.manager.jobObjects.zoneSwapPending then
        modules.manager.jobObjects.zoneSwapTargetZone = selectedZone
        contract.group = selectedZone
        contract.loadingZoneTag = selectedZone.secondaryTag
        local oldGroup = modules.manager.jobObjects.activeGroup
        modules.manager.jobObjects.materialType = selectedZone.materialType or contract.material or "rocks"
        modules.manager.jobObjects.activeGroup = selectedZone

        modules.manager.clearUnloadedProps(oldGroup)
        local playerVehicle = be:getPlayerVehicle(0)
        local playerPosition = playerVehicle and playerVehicle:getPosition() or cachedPlayerPos
        modules.manager.spawnJobMaterials(modules.contracts, modules.zones, playerPosition)

        compatibleZones = {}
        currentState = modules.config.STATE_DELIVERING
        publishZoneSelection(selectedZone, "Zone selected: %s. Truck will spawn when you enter the zone.")
        return
      else
        contract.group = selectedZone
        contract.loadingZoneTag = selectedZone.secondaryTag
        local oldGroup = modules.manager.jobObjects.activeGroup
        modules.manager.jobObjects.materialType = selectedZone.materialType or contract.material or "rocks"
        modules.manager.jobObjects.truckSpawnQueued = true
        local playerVehicle = be:getPlayerVehicle(0)
        local playerPosition = playerVehicle and playerVehicle:getPosition() or cachedPlayerPos

        modules.manager.clearUnloadedProps(oldGroup)
        modules.manager.jobObjects.activeGroup = selectedZone
        modules.manager.spawnJobMaterials(modules.contracts, modules.zones, playerPosition)

        currentState = modules.config.STATE_DRIVING_TO_SITE
        modules.manager.markerCleared = false
        compatibleZones = {}
        publishZoneSelection(selectedZone, "Zone selected: %s. Drive to zone.")
      end
    end
  end,
  onAbandonContract = function()
    modules.contracts.abandonContract(function(deleteTruck)
      modules.manager.cleanupJob(deleteTruck, modules.config.STATE_IDLE)
      currentState = modules.config.STATE_IDLE
      compatibleZones = {}
    end)
  end,
  onSendTruck = function()
    if currentState == modules.config.STATE_DELIVERING then
      return
    end
    if not modules.manager.jobObjects.truckID then
      return
    end
    local truck = be:getObjectByID(modules.manager.jobObjects.truckID)
    if not truck then
      modules.manager.jobObjects.truckID = nil
      return
    end
    local destinationPosition = modules.manager.jobObjects.deliveryDestination and vec3(modules.manager.jobObjects.deliveryDestination.pos) or (modules.manager.jobObjects.activeGroup and modules.manager.jobObjects.activeGroup.destination and vec3(modules.manager.jobObjects.activeGroup.destination.pos))
    if destinationPosition then
      local materialType = modules.manager.jobObjects.materialType
      local materialConfig = materialType and modules.config.materials and modules.config.materials[materialType]
      if materialConfig and materialConfig.unitType == "item" then
        modules.manager.jobObjects.lastDeliveredMass = 0
        modules.manager.jobObjects.deliveryBlocksStatus = modules.manager.getItemBlocksStatus()
      else
        modules.manager.jobObjects.lastDeliveredMass = modules.manager.jobObjects.currentLoadMass or 0
      end
      modules.manager.jobObjects.deliveredPropIds = modules.manager.getLoadedPropIdsInTruck(IN_TRUCK_MIN_RATIO)
      modules.manager.deliveryTimer = 0
      modules.manager.truckStoppedTimer = 0
      modules.manager.truckLastPosition = nil
      modules.manager.truckDamage = 0
      modules.manager.damageCheckQueued = false
      modules.manager.teleportQueued = false
      core_groundMarkers.setPath(nil)
      modules.manager.driveTruckToPoint(modules.manager.jobObjects.truckID, destinationPosition)
      currentState = modules.config.STATE_DELIVERING
    end
  end,
  onFinalizeContract = function()
    modules.contracts.completeContract(function(deleteTruck)
      modules.manager.cleanupJob(deleteTruck, modules.config.STATE_IDLE)
      currentState = modules.config.STATE_IDLE
      if overhaul_career_career.isActive() then
        overhaul_career_saveSystem.saveCurrent()
      end
    end, modules.manager.clearProps)
  end,
  onLoadMore = function()
    if modules.manager.beginActiveContractTrip(modules.contracts, modules.zones, modules.ui) then
      currentState = modules.config.STATE_DRIVING_TO_SITE
    end
  end,
  onSetZoneWaypoint = function(zoneTag)
    if not zoneTag then return end

    for _, zone in ipairs(modules.zones.availableGroups or {}) do
      if zone.secondaryTag == zoneTag and zone.loading and zone.loading.center then
        local targetPosition = vec3(zone.loading.center)
        core_groundMarkers.setPath(targetPosition)
        local cache = modules.zones.ensureGroupCache and modules.zones.ensureGroupCache(zone, modules.contracts.getCurrentGameHour) or nil
        local zoneName = cache and cache.name or zoneTag
        ui_message(string.format("Waypoint set to %s", zoneName), 5, "info")
        return
      end
    end
  end
}

-- Player cache and truck dispatch ---------------------------------------------------------------

local function getVehiclePosition(vehicle)
  return vehicle:getPosition()
end

local function updatePlayerCache(dt)
  playerCacheTimer = playerCacheTimer + dt
  local checkInterval = quarrySettings.value(modules.config.settings.zones, "zones", "checkInterval")
  if playerCacheTimer < checkInterval then
    return false
  end
  cachedPlayerVeh = be:getPlayerVehicle(0)
  if cachedPlayerVeh then
    local success, pos = pcall(getVehiclePosition, cachedPlayerVeh)
    if success then
      cachedPlayerPos = pos
    else
      cachedPlayerVeh = nil
      cachedPlayerPos = nil
    end
  else
    cachedPlayerPos = nil
  end
  playerCacheTimer = 0
  return true
end

local function forceBrakesAndDisableAI(truckId, truck)
  if not truck or not truckId then return end
  -- Keep the manager's nudge latch and pending-route generation synchronized
  -- when the proximity pass takes control before the arrival state settles.
  modules.manager.stopTruck(truckId)
end

local function handleTruckNudging(truckId, truck, targetPosition, arrivalDist, atTarget)
  if not truck or not targetPosition or not modules.manager then return false end
  local truckPos = truck:getPosition()
  local distToTarget = (truckPos - targetPosition):length()
  local timeSinceRoute = os.clock() - (modules.manager.truckRouteStartTime or 0)
  local canNudge = timeSinceRoute > 5 and distToTarget < 30
  if atTarget or not canNudge then return false end
  local truckSpeed = truck:getVelocity():length()
  if not modules.manager.truckNudging and truckSpeed >= 0.5 then return false end
  if distToTarget <= arrivalDist then
    return false
  end
  modules.manager.truckNudging = true
  local throttle = 0
  local brake = 0
  local dirToTarget = (targetPosition - truckPos):normalized()
  local truckDir = truck:getDirectionVector():normalized()
  local truckRight = truck:getDirectionVectorUp():cross(truckDir):normalized()
  local steerDot = truckRight:dot(dirToTarget)
  local steering = math.max(-1, math.min(1, -steerDot * 2))
  -- This only takes over once the route driver has stopped. Keep the last few
  -- metres deliberate so a heavy truck cannot overshoot the designated stop.
  local targetSpeed = 5.0
  if distToTarget < 2 then
    targetSpeed = 0.4
  elseif distToTarget < 4 then
    targetSpeed = 0.75
  elseif distToTarget < 7 then
    targetSpeed = 1.4
  elseif distToTarget < 12 then
    targetSpeed = 2.4
  elseif distToTarget < 20 then
    targetSpeed = 3.5
  end
  local speedError = targetSpeed - truckSpeed
  local speedControlGain = 0.3
  if speedError > 0.1 then
    throttle = math.min(1.0, speedError * speedControlGain)
  elseif speedError < -0.1 then
    brake = math.min(0.8, -speedError * speedControlGain * 0.8)
  end
  modules.manager.nudgeTruckWithControl(truckId, throttle, brake, steering)
  return true
end

local function spawnOrMoveTruckToZone(zone, isZoneSwap)
  if not zone or not zone.loading or not zone.spawn or not zone.spawn.pos then
    return false
  end
  local truckExists = false
  if modules.manager.jobObjects.truckID then
    local truck = be:getObjectByID(modules.manager.jobObjects.truckID)
    truckExists = truck ~= nil
    if not truckExists then
      modules.manager.jobObjects.truckID = nil
    end
  end
  local shouldSpawnTruck = not modules.manager.jobObjects.truckID
  local truckReady = false
  if shouldSpawnTruck then
    truckReady = true
  elseif truckExists then
    if isZoneSwap then
      truckReady = modules.manager.jobObjects.zoneSwapTruckAtDestination or false
    else
      truckReady = modules.manager.jobObjects.truckSpawnQueued or false
    end
  end
  if not truckReady then
    return false
  end
  local targetPosition = modules.manager.getLoadingZoneTargetPos(zone)
  modules.manager.jobObjects.loadingZoneTargetPos = targetPosition
  if shouldSpawnTruck then
    local truckId = modules.manager.spawnTruckForGroup(zone, modules.manager.jobObjects.materialType, targetPosition)
    if truckId then
      modules.manager.jobObjects.truckID = truckId
      modules.manager.driveTruckToPoint(truckId, targetPosition)
      modules.manager.jobObjects.truckSpawnQueued = false
      return true
    end
  elseif truckExists and modules.manager.jobObjects.truckID then
    local truck = be:getObjectByID(modules.manager.jobObjects.truckID)
    if truck then
      local pos, rot = modules.manager.calculateSpawnTransformForLocation(vec3(zone.spawn.pos), targetPosition)
      spawn.safeTeleport(truck, pos, rot, nil, nil, nil, true)
      modules.manager.driveTruckToPoint(modules.manager.jobObjects.truckID, targetPosition)
      return true
    else
      modules.manager.jobObjects.truckID = nil
      local truckId = modules.manager.spawnTruckForGroup(zone, modules.manager.jobObjects.materialType, targetPosition)
      if truckId then
        modules.manager.jobObjects.truckID = truckId
        modules.manager.driveTruckToPoint(truckId, targetPosition)
        modules.manager.jobObjects.truckSpawnQueued = false
        return true
      end
    end
  end
  return false
end

local function getVehicleJBeamFilename(vehicle)
  return vehicle:getJBeamFilename()
end

local function cleanupAbandonedJob(deleteTruck)
  modules.manager.cleanupJob(deleteTruck, modules.config.STATE_IDLE)
end

-- Idle and selection phases ---------------------------------------------------------------------

local function setCurrentState(state)
  currentState = state
end

local function updateIdle(dt, config, contracts, zones, manager, playerVehicle, playerPosition)
  if contracts.ContractSystem.activeContract then
    compatibleZones = zones.getZonesByTypeName(contracts.ContractSystem.activeContract.materialTypeName) or {}
    currentState = contracts.checkContractCompletion() and config.STATE_AT_QUARRY_DECIDE or config.STATE_CHOOSING_ZONE
    triggerPhoneState()
    return true
  end
  if manager.jobOfferSuppressed and not zones.isPlayerInAnyLoadingZone(playerPosition) then
    manager.jobOfferSuppressed = false
  end
  if not manager.jobOfferSuppressed and playerVehicle then
    local success, jbeamFilename = pcall(getVehicleJBeamFilename, playerVehicle)
    if success and jbeamFilename == "wl40" then
      if zones.isPlayerInAnyLoadingZone(playerPosition) then
        local currentZone = zones.getPlayerCurrentZone and zones.getPlayerCurrentZone(playerPosition)
        local zoneTag = currentZone and currentZone.secondaryTag
        if contracts.shouldRefreshContracts(zoneTag) or not contracts.ContractSystem.initialContractsGenerated then
          contracts.generateInitialContracts(zones.availableGroups)
        end
        currentState = config.STATE_CONTRACT_SELECT
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_Unlock_01')
      end
    end
  end
end

local function updateContractSelection(dt, config, contracts, zones, manager, playerVehicle, playerPosition)
  contractUpdateTimer = contractUpdateTimer + dt
  if contractUpdateTimer >= 1.0 then
    contractUpdateTimer = 0
    contracts.checkContractExpiration()
    contracts.trySpawnNewContract(zones.availableGroups)
  end
  if #contracts.ContractSystem.availableContracts == 0 and #zones.availableGroups > 0 then
    if not contracts.isCareerMode() then
      contracts.generateInitialContracts(zones.availableGroups)
    end
  end
  if not zones.isPlayerInAnyLoadingZone(playerPosition) then
    currentState = config.STATE_IDLE
  end
end
-- Where the truck should stop for the current state, or nil when it is not on a route.
-- Zone swap delivery phases ---------------------------------------------------------------------

local function routeTargetPosition()
  local jobs = modules.manager.jobObjects
  if currentState == modules.config.STATE_DELIVERING or jobs.zoneSwapPending then
    return deliveryDestinationPosition()
  end
  if currentState ~= modules.config.STATE_TRUCK_ARRIVING and currentState ~= modules.config.STATE_LOADING then return nil end
  local group = jobs.activeGroup
  if not group then return nil end
  local routingTargetPos = modules.manager.getLoadingZoneTargetPos(group)
  local firstStop = group.stopLocations and group.stopLocations[1]
  local stopLocationPos = firstStop and firstStop.pos and vec3(firstStop.pos) or nil
  return stopLocationPos or routingTargetPos
end

local function stopTruckAtRouteTarget(settingsTruck)
  local truckId = modules.manager.jobObjects.truckID
  if not truckId then return end
  local truck = be:getObjectByID(truckId)
  if not truck then return end
  local arrivalDist = quarrySettings.value(settingsTruck, "truck", "arrivalDistanceThreshold")
  local truckPos = truck:getPosition()
  local targetPosition = routeTargetPosition()
  if targetPosition and (truckPos - targetPosition):length() < arrivalDist then
    forceBrakesAndDisableAI(truckId, truck)
  end
end

local function deleteJobTruck()
  local jobs = modules.manager.jobObjects
  if not jobs.truckID then return end
  local truckObj = be:getObjectByID(jobs.truckID)
  if truckObj then truckObj:delete() end
  jobs.truckID = nil
end

local function tallyZoneSwapItems(contract, progress)
  local deliveredSet = {}
  for _, id in ipairs(modules.manager.jobObjects.zoneSwapLoadedPropIds) do deliveredSet[id] = true end
  if not progress.deliveredItemsByMaterial then
    progress.deliveredItemsByMaterial = {}
  end
  for _, entry in ipairs(modules.manager.propQueue) do
    if entry.id and deliveredSet[entry.id] and entry.materialType then
      local entryMatConfig = modules.config.materials and modules.config.materials[entry.materialType]
      if entryMatConfig and entryMatConfig.typeName == contract.materialTypeName then
        progress.deliveredItems = (progress.deliveredItems or 0) + 1
        progress.deliveredItemsByMaterial[entry.materialType] = (progress.deliveredItemsByMaterial[entry.materialType] or 0) + 1
      end
    end
  end
end

local function creditZoneSwapDelivery(contract)
  local jobs = modules.manager.jobObjects
  local materialType = jobs.materialType
  local materialConfig = materialType and modules.config.materials and modules.config.materials[materialType]
  if materialConfig and materialConfig.unitType == "item" then
    jobs.deliveryBlocksStatus = jobs.zoneSwapDeliveryBlocksStatus
  end
  local progress = modules.contracts.ContractSystem.contractProgress
  local tons = (jobs.zoneSwapDeliveredMass or 0) / 1000
  progress.deliveredTons = (progress.deliveredTons or 0) + tons
  progress.deliveryCount = (progress.deliveryCount or 0) + 1
  if contract.materialTypeName and contract.unitType == "item" then
    tallyZoneSwapItems(contract, progress)
  end
end

local function endSwapWithCompletedContract()
  local jobs = modules.manager.jobObjects
  jobs.zoneSwapPending = false
  jobs.zoneSwapTargetZone = nil
  jobs.zoneSwapTruckAtDestination = false
  jobs.zoneSwapClearPropsOnArrival = false
  modules.manager.clearProps()
  deleteJobTruck()
  jobs.truckStoppedInLoading, modules.manager.markerCleared = false, true
  currentState = modules.config.STATE_AT_QUARRY_DECIDE
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_End_Success')
  ui_message("Contract complete! Ready to finalize.", 6, "success")
  core_groundMarkers.setPath(nil)
end

-- Books the swap's cargo against the active contract. True when that completed the contract.
local function settleZoneSwapDelivery()
  local contract = modules.contracts.ContractSystem.activeContract
  if not contract then return false end
  local jobs = modules.manager.jobObjects
  creditZoneSwapDelivery(contract)
  modules.manager.despawnPropIds(jobs.zoneSwapLoadedPropIds, modules.zones, modules.contracts, true)
  jobs.zoneSwapLoadedPropIds = nil
  jobs.deliveredPropIds = nil
  jobs.deliveryBlocksStatus = nil
  jobs.zoneSwapDeliveryBlocksStatus = nil
  if not modules.contracts.checkContractCompletion() then return false end
  endSwapWithCompletedContract()
  return true
end

local function updateZoneSwapArrival(settingsTruck)
  local jobs = modules.manager.jobObjects
  if not (jobs.zoneSwapPending and jobs.zoneSwapTargetZone and jobs.truckID) then return end
  local truck = be:getObjectByID(jobs.truckID)
  if not truck then return end
  local destinationPosition = deliveryDestinationPosition()
  if not destinationPosition then return end
  local arrivalDist = quarrySettings.value(settingsTruck, "truck", "arrivalDistanceThreshold")
  local truckPos = truck:getPosition()
  if jobs.zoneSwapTruckAtDestination or (truckPos - destinationPosition):length() >= arrivalDist then return end
  jobs.zoneSwapTruckAtDestination = true
  modules.manager.stopTruck(jobs.truckID)
  local hasCargo = jobs.zoneSwapLoadedPropIds and #jobs.zoneSwapLoadedPropIds > 0
  if hasCargo and settleZoneSwapDelivery() then return true end
  if jobs.zoneSwapClearPropsOnArrival then
    if not jobs.zoneSwapTargetZone then
      modules.manager.clearProps()
    end
    jobs.zoneSwapClearPropsOnArrival = false
    deleteJobTruck()
  end
end

local function updateZoneSwapLoading(playerPosition)
  if modules.manager.jobObjects.zoneSwapPending and modules.manager.jobObjects.zoneSwapTargetZone then
    local selectedZone = modules.manager.jobObjects.zoneSwapTargetZone
    if selectedZone.loading and selectedZone.loading:containsPoint2D(playerPosition) then
      if modules.manager.jobObjects.truckID then
        local truck = be:getObjectByID(modules.manager.jobObjects.truckID)
        if not truck then
          modules.manager.jobObjects.truckID = nil
        end
      end
      if modules.manager.jobObjects.zoneSwapTruckAtDestination and spawnOrMoveTruckToZone(selectedZone, true) then
        currentState = modules.config.STATE_LOADING
        modules.manager.truckStoppedInLoading = false
        modules.manager.markerCleared = false
        modules.manager.jobObjects.zoneSwapPending = false
        modules.manager.jobObjects.zoneSwapTargetZone = nil
        modules.manager.jobObjects.zoneSwapTruckAtDestination = false
        modules.manager.jobObjects.zoneSwapClearPropsOnArrival = false
        modules.manager.deliveryTimer = 0
        modules.manager.truckStoppedTimer = 0
        modules.manager.truckLastPosition = nil
        core_groundMarkers.setPath(nil)
      end
    end
  end
end

local function createStateHandlers()
  return require('overhaul/jobs/quarry/updateStates')(modules.config, setCurrentState,
    spawnOrMoveTruckToZone, handleTruckNudging, cleanupAbandonedJob,
    updateIdle, updateContractSelection)
end

-- Save capture ----------------------------------------------------------------------------------

local function emptyFacilitySave()
  return {contracts = {availableContracts = {}, activeContract = nil, contractProgress = {},
    nextContractSpawnTime = nil, initialContractsGenerated = false}, zoneStocks = {}}
end

local function captureFacilityContracts(contracts, saveData)
  local facilitiesByContract = {}
  local activeContractFacilityId = nil
  for _, contract in ipairs(contracts.ContractSystem.availableContracts or {}) do
    local facilityId = contract.facilityId
    if not facilityId and (contract.groupTag or contract.loadingZoneTag) then
      facilityId = contracts.getFacilityIdForZone(contract.groupTag or contract.loadingZoneTag)
    end
    if facilityId then
      if not facilitiesByContract[facilityId] then
        facilitiesByContract[facilityId] = {}
      end
      table.insert(facilitiesByContract[facilityId], contracts.serializeContract(contract))
    end
  end
  if contracts.ContractSystem.activeContract then
    local contract = contracts.ContractSystem.activeContract
    activeContractFacilityId = contract.facilityId
    if not activeContractFacilityId and (contract.groupTag or contract.loadingZoneTag) then
      activeContractFacilityId = contracts.getFacilityIdForZone(contract.groupTag or contract.loadingZoneTag)
    end
  end
  for facilityId, contracts in pairs(facilitiesByContract) do
    if not saveData[facilityId] then
      saveData[facilityId] = emptyFacilitySave()
    end
    saveData[facilityId].contracts.availableContracts = contracts
  end
  if activeContractFacilityId and contracts.ContractSystem.activeContract then
    if not saveData[activeContractFacilityId] then
      saveData[activeContractFacilityId] = emptyFacilitySave()
    end
    saveData[activeContractFacilityId].contracts.activeContract = contracts.serializeContract(contracts.ContractSystem.activeContract)
    saveData[activeContractFacilityId].contracts.contractProgress = contracts.ContractSystem.contractProgress or {}
  end
end

local function captureZoneStocks(zones, saveData)
  for zoneTag, cache in pairs(zones.groupCache or {}) do
    local facilityId = zones.getFacilityIdForZone(zoneTag)
    if facilityId and zones.validateZoneBelongsToFacility(zoneTag, facilityId) then
      if not saveData[facilityId] then
        saveData[facilityId] = emptyFacilitySave()
      end
      if cache.materialStocks then
        local zoneStockData = {
          locationVersion = zoneTag:find("::", 1, true) and 2 or nil,
          materialStocks = {},
          spawnedPropCounts = cache.spawnedPropCounts or {}
        }
        for matKey, stock in pairs(cache.materialStocks) do
          zoneStockData.materialStocks[matKey] = {
            current = stock.current,
            max = stock.max,
            regenRate = stock.regenRate,
            nextRegenSimTime = stock.nextRegenSimTime
          }
        end
        saveData[facilityId].zoneStocks[zoneTag] = zoneStockData
      end
    end
  end
end

local function saveLoadingData(currentSavePath, writer)
  local config, contracts, zones = modules.config, modules.contracts, modules.zones
  if not quarryPersistence.isCurrent() then return end
  if not overhaul_career_career.isActive() then return end
  if not contracts or not zones or not config then return end
  local profileName, latestSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not profileName or loadedProfileName ~= profileName then
    log('W', 'overhaul_jobs_quarry_quarry', 'Skipping loading.json save: quarry data not loaded yet for profile ' .. tostring(profileName))
    return
  end
  if not currentSavePath then
    currentSavePath = latestSavePath
    if not currentSavePath then return end
  end
  local dirPath = currentSavePath .. "/career/rls_career"
  if not writer.exists(dirPath) then
    writer.mkdir(dirPath)
  end
  local saveData = {}
  captureFacilityContracts(contracts, saveData)
  local earliestSpawnTime = contracts.ContractSystem.nextContractSpawnSimTime
  local simTime = contracts.getSimTime and contracts.getSimTime() or nil
  for facilityId, facilityData in pairs(saveData) do
    if earliestSpawnTime then
      facilityData.contracts.nextContractSpawnTime = earliestSpawnTime
    end
    facilityData.contracts.initialContractsGenerated = contracts.ContractSystem.initialContractsGenerated or false
  end
  captureZoneStocks(zones, saveData)
  for _, facilityData in pairs(saveData) do
    facilityData.contracts.simTimeAccumulator = simTime
  end
  if latestSavePath then
    local previousData = quarryPersistence.restore(latestSavePath)
    if type(previousData) == "table" then
      for facilityId, facilityData in pairs(previousData) do
        if saveData[facilityId] == nil and not (config.facilities and config.facilities[facilityId]) then
          saveData[facilityId] = facilityData
        end
      end
    end
  end
  quarryPersistence.write(currentSavePath, saveData)
end

-- Save restore ----------------------------------------------------------------------------------

local function deserializeFacilityContract(serialized, facilityId)
  local contract = modules.contracts.deserializeContract(serialized)
  if not contract then return nil end
  if not contract.facilityId then
    contract.facilityId = facilityId
  end
  if contract.facilityId ~= facilityId then return nil end
  local facility = modules.config.facilities[facilityId]
  for _, key in ipairs({"groupTag", "loadingZoneTag"}) do
    if contract[key] and facility.sites and not facility.sites[contract[key]] then
      contract[key] = levelData.resolveAlias("quarryZone", contract[key], {levelId = getCurrentLevelIdentifier(), facilityId = facilityId, saveVersion = serialized.locationVersion or 1})
    end
  end
  if contract.destination and contract.destination.originZoneTag and facility.sites and not facility.sites[contract.destination.originZoneTag] then
    contract.destination.originZoneTag = levelData.resolveAlias("quarryZone", contract.destination.originZoneTag, {levelId = getCurrentLevelIdentifier(), facilityId = facilityId, saveVersion = serialized.locationVersion or 1})
  end
  return contract
end

-- contract wins, the clock keeps its largest value and the spawn time its earliest.
local function restoreFacilityContracts(facilityId, saved, restored)
  if type(saved.simTimeAccumulator) == "number" then
    restored.simTime = math.max(restored.simTime or 0, saved.simTimeAccumulator)
  end
  for _, serialized in ipairs(saved.availableContracts or {}) do
    local contract = deserializeFacilityContract(serialized, facilityId)
    if contract then
      table.insert(restored.availableContracts, contract)
    end
  end
  if saved.activeContract and not restored.activeContract then
    local contract = deserializeFacilityContract(saved.activeContract, facilityId)
    if contract then
      restored.activeContract = contract
      restored.contractProgress = saved.contractProgress or {}
    end
  end
  if saved.nextContractSpawnTime
    and (not restored.nextSpawnTime or saved.nextContractSpawnTime < restored.nextSpawnTime) then
    restored.nextSpawnTime = saved.nextContractSpawnTime
  end
  if saved.initialContractsGenerated then
    restored.initialContractsGenerated = true
  end
end

-- Saved stock levels overwrite the live ones field by field. The regen time is only trusted
-- when the same save also stored the simulation clock it was measured against.
local function restoreMaterialStocks(liveStocks, savedStocks, clockWasSaved)
  for matKey, stockData in pairs(savedStocks) do
    local stock = liveStocks[matKey]
    if stock then
      stock.current = stockData.current or stock.current
      stock.max = stockData.max or stock.max
      stock.regenRate = stockData.regenRate or stock.regenRate
      if stockData.nextRegenSimTime and clockWasSaved then
        stock.nextRegenSimTime = stockData.nextRegenSimTime
      end
    end
  end
end

local function restoreZoneStocks(facilityId, zoneStocks, clockWasSaved)
  for savedZoneTag, zoneStockData in pairs(zoneStocks) do
    local zoneTag = savedZoneTag
    local facility = modules.config.facilities[facilityId]
    if facility.sites and not facility.sites[zoneTag] then
      zoneTag = levelData.resolveAlias("quarryZone", savedZoneTag, {levelId = getCurrentLevelIdentifier(), facilityId = facilityId, saveVersion = zoneStockData.locationVersion or 1})
    end
    if modules.zones.validateZoneBelongsToFacility(zoneTag, facilityId) then
      local cache = modules.zones.ensureGroupCache({secondaryTag = zoneTag}, modules.contracts.getCurrentGameHour)
      if cache and zoneStockData.materialStocks then
        restoreMaterialStocks(cache.materialStocks, zoneStockData.materialStocks, clockWasSaved)
      end
      if cache and zoneStockData.spawnedPropCounts then
        cache.spawnedPropCounts = zoneStockData.spawnedPropCounts
      end
    end
  end
end

local function attachActiveContractZone(activeContract)
  local zoneTag = activeContract.groupTag or activeContract.loadingZoneTag
  if not zoneTag then return end
  for _, group in ipairs(modules.zones.availableGroups or {}) do
    if group.secondaryTag == zoneTag then
      activeContract.group = group
      activeContract.loadingZoneTag = zoneTag
      return
    end
  end
end

local function loadLoadingData()
  if not overhaul_career_career.isActive() then return end
  if not modules.contracts or not modules.zones or not modules.config then return end
  if not modules.zones.sitesData then
    modules.zones.loadQuarrySites(modules.contracts.getCurrentGameHour)
  end
  local profileName, path = overhaul_career_saveSystem.getCurrentProfile()
  if not profileName then return end
  if not path then
    loadedProfileName = profileName
    return
  end
  local saveData = quarryPersistence.restore(path) or {}
  if not saveData or next(saveData) == nil then
    loadedProfileName = profileName
    return
  end
  local restored = {availableContracts = {}, contractProgress = {}, initialContractsGenerated = false}
  local foundFacility = false
  for facilityId, facilityData in pairs(saveData) do
    if modules.config.facilities and modules.config.facilities[facilityId] then
      foundFacility = true
      if facilityData.contracts then
        restoreFacilityContracts(facilityId, facilityData.contracts, restored)
      end
      if facilityData.zoneStocks then
        local clockWasSaved = type(facilityData.contracts) == "table" and facilityData.contracts.simTimeAccumulator
        restoreZoneStocks(facilityId, facilityData.zoneStocks, clockWasSaved)
      end
    end
  end
  if not foundFacility then
    loadedProfileName = profileName
    return
  end
  if restored.simTime then
    modules.contracts.ContractSystem.simTimeAccumulator = restored.simTime
    modules.contracts.ContractSystem.nextContractSpawnSimTime = restored.nextSpawnTime
  else
    -- Legacy absolute times have no saved clock and must be reseeded.
    modules.contracts.ContractSystem.nextContractSpawnSimTime = nil
  end
  modules.contracts.ContractSystem.availableContracts = restored.availableContracts
  modules.contracts.ContractSystem.activeContract = restored.activeContract
  modules.contracts.ContractSystem.contractProgress = restored.contractProgress
  modules.contracts.ContractSystem.initialContractsGenerated = restored.initialContractsGenerated
  if restored.activeContract then
    attachActiveContractZone(restored.activeContract)
  end
  modules.contracts.sortContracts()
  if restored.activeContract then
    compatibleZones = modules.zones.getZonesByTypeName(restored.activeContract.materialTypeName) or {}
    currentState = modules.contracts.checkContractCompletion() and modules.config.STATE_AT_QUARRY_DECIDE or modules.config.STATE_CHOOSING_ZONE
    triggerPhoneState()
  end
  loadedProfileName = profileName
end

-- Per-frame update --------------------------------------------------------------------------------

local function onUpdate(dt, dtSim)
  if not modules.config or not modules.contracts or not modules.zones or not modules.manager or not modules.ui then return end
  if modules.contracts.updateSimTime then
    modules.contracts.updateSimTime(dtSim or dt)
  end
  local settingsZones = modules.config.settings and modules.config.settings.zones
  local settingsPayload = modules.config.settings and modules.config.settings.payload
  local settingsTruck = modules.config.settings and modules.config.settings.truck
  local settingsUI = modules.config.settings and modules.config.settings.ui
  local playerCacheRefreshed = updatePlayerCache(dt)
  if not cachedPlayerVeh or not cachedPlayerPos then return end
  local playerVehicle = cachedPlayerVeh
  local playerPosition = cachedPlayerPos
  stopTruckAtRouteTarget(settingsTruck)
  if not modules.zones.sitesData then
    modules.zones.sitesLoadTimer = modules.zones.sitesLoadTimer + dt
    local retryInterval = settingsZones and settingsZones.sitesLoadRetryInterval or 1.0
    if modules.zones.sitesLoadTimer >= retryInterval then
      modules.zones.loadQuarrySites(modules.contracts.getCurrentGameHour)
      modules.zones.sitesLoadTimer = 0
    end
  end
  zoneStockUpdateTimer = zoneStockUpdateTimer + dt
  if modules.contracts.getSimTime and zoneStockUpdateTimer >= ZONE_STOCK_UPDATE_INTERVAL then
    modules.zones.updateZoneStocks(zoneStockUpdateTimer, modules.contracts.getSimTime)
    zoneStockUpdateTimer = 0
  end
  -- Idle quarry discovery only needs the same 10 Hz cadence as the player
  -- position cache. Active contracts retain their frame-accurate state machine.
  if currentState == modules.config.STATE_IDLE and not playerCacheRefreshed then
    return
  end
  modules.ui.drawWorkSiteMarker(dt, currentState, modules.config.STATE_DRIVING_TO_SITE, modules.manager.markerCleared, modules.manager.jobObjects.activeGroup)
  modules.ui.drawZoneChoiceMarkers(dt, currentState, modules.config.STATE_CHOOSING_ZONE, compatibleZones)
  if currentState == modules.config.STATE_LOADING then
    modules.manager.payloadUpdateTimer = modules.manager.payloadUpdateTimer + dt
    local payloadInterval = quarrySettings.value(settingsPayload, "payload", "updateInterval")
    if modules.manager.payloadUpdateTimer >= payloadInterval then
      modules.manager.jobObjects.currentLoadMass = modules.manager.calculateTruckPayload()
      modules.manager.calculateItemDamage()
      modules.manager.processPendingRespawns(dt, modules.zones, modules.contracts)
      modules.manager.payloadUpdateTimer = 0
    end
  end
  modules.ui.drawDebugOBB()
  if updateZoneSwapArrival(settingsTruck) then return end
  updateZoneSwapLoading(playerPosition)
  local handler = stateHandlers[currentState]
  if handler and handler(dt, modules.config, modules.contracts, modules.zones, modules.manager, playerVehicle,
    playerPosition, settingsPayload, settingsTruck) then return end
  local uiUpdateInterval = quarrySettings.value(settingsUI, "ui", "updateInterval")
  if currentState ~= modules.config.STATE_IDLE then
    uiUpdateTimer = uiUpdateTimer + dt
    if uiUpdateTimer >= uiUpdateInterval then
      uiUpdateTimer = 0
      triggerPhoneState()
    end
  end
end

local function loadSubModules()
  loadedExtensions = require('overhaul/lib/shell/childExtensions').load({'overhaul_jobs_quarry_config',
    'overhaul_jobs_quarry_contracts', 'overhaul_jobs_quarry_manager', 'overhaul_jobs_quarry_ui', 'overhaul_jobs_quarry_zones'}) or loadedExtensions
  modules.config = overhaul_jobs_quarry_config
  modules.contracts = overhaul_jobs_quarry_contracts
  modules.zones = overhaul_jobs_quarry_zones
  modules.manager = overhaul_jobs_quarry_manager
  modules.ui = overhaul_jobs_quarry_ui
  if modules.config then currentState = modules.config.STATE_IDLE end
  stateHandlers = modules.config and createStateHandlers() or nil
end

-- Lifecycle -----------------------------------------------------------------------------

local function onExtensionLoaded()
  loadSubModules()
end

local function onExtensionUnloaded()
  if modules.manager then
    modules.manager.cleanupJob(true, modules.config and modules.config.STATE_IDLE or nil)
  end
  unloadSubModules()
  modules.config, modules.contracts, modules.zones, modules.manager, modules.ui = nil, nil, nil, nil, nil
  currentState = nil
  stateHandlers = nil
  compatibleZones = {}
  cachedPlayerVeh = nil
  cachedPlayerPos = nil
  playerCacheTimer = 0
  zoneStockUpdateTimer = 0
  uiUpdateTimer = 0
  contractUpdateTimer = 0
  quarryPersistence.dispose()
end

-- Truck and loaded props must be gone before a Lua reload serializes stock checkpoints; the guard keeps a
require('overhaul/lib/vehicles/temporary').declare('quarry', function()
  if modules.manager then modules.manager.cleanupJob(true, modules.config and modules.config.STATE_IDLE or nil) end
end)

local function onClientStartMission()
  if not modules.zones then return end
  modules.zones.sitesData, modules.zones.availableGroups, modules.zones.groupCache = nil, {}, {}
  modules.manager.cleanupJob(true, modules.config.STATE_IDLE)
  modules.contracts.ContractSystem.availableContracts, modules.contracts.ContractSystem.activeContract = {}, nil
  modules.contracts.ContractSystem.nextContractSpawnSimTime = nil
  modules.contracts.ContractSystem.initialContractsGenerated = false
  currentState = modules.config.STATE_IDLE
  compatibleZones = {}
  cachedPlayerVeh = nil
  cachedPlayerPos = nil
  playerCacheTimer = 0
  zoneStockUpdateTimer = 0
  loadedProfileName = nil
end

local function onClientEndMission()
  loadedProfileName = nil
  if not modules.manager then return end
  modules.manager.cleanupJob(true, modules.config.STATE_IDLE)
  modules.zones.sitesData, modules.zones.availableGroups, modules.zones.groupCache = nil, {}, {}
  modules.contracts.ContractSystem.availableContracts, modules.contracts.ContractSystem.activeContract = {}, nil
  modules.contracts.ContractSystem.nextContractSpawnSimTime = nil
  currentState = modules.config.STATE_IDLE
  zoneStockUpdateTimer = 0
end

local function onItemDamageCallback(objId, isDamaged)
  if modules.manager then
    modules.manager.itemDamageState[objId] = { isDamaged = isDamaged, lastUpdate = os.clock() }
  end
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  saveLoadingData(currentSavePath, writer)
end

local LOAD_WAIT_FOR_SITES_SECONDS = 20

local function onOverhaulModulesActivated(alreadyInLevel)
  if not (modules.contracts and modules.zones and modules.config) then return end
  loadedProfileName = nil
  loadJobSequence = loadJobSequence + 1
  local sequence = loadJobSequence
  core_jobsystem.create(function(job)
    job.sleep(0.5)
    if not (modules.contracts and modules.zones and modules.config) then return end
    if not modules.config.facilities or next(modules.config.facilities) == nil then
      if modules.config.loadConfiguration then modules.config.loadConfiguration() end
    end
    local waited = 0
    while sequence == loadJobSequence and modules.zones and not modules.zones.sitesData and modules.config and modules.config.facilities
      and next(modules.config.facilities) ~= nil and waited < LOAD_WAIT_FOR_SITES_SECONDS do
      modules.zones.loadQuarrySites(modules.contracts.getCurrentGameHour)
      if modules.zones.sitesData then break end
      job.sleep(0.5)
      waited = waited + 0.5
    end
    if sequence ~= loadJobSequence or not (modules.contracts and modules.zones and modules.config) then return end
    if not overhaul_career_career.isActive() then return end
    loadLoadingData()
  end)
end

local function resetQuarryRuntimeState()
  if not (modules.manager and modules.contracts and modules.zones and modules.config) then return end
  modules.manager.cleanupJob(true, modules.config.STATE_IDLE)
  modules.contracts.ContractSystem.availableContracts, modules.contracts.ContractSystem.activeContract = {}, nil
  modules.contracts.ContractSystem.contractProgress = {}
  modules.contracts.ContractSystem.nextContractSpawnSimTime = nil
  modules.contracts.ContractSystem.initialContractsGenerated = false
  modules.contracts.ContractSystem.simTimeAccumulator = 0
  modules.zones.groupCache = {}
  currentState = modules.config.STATE_IDLE
  compatibleZones = {}
end

local function onOverhaulActive(active)
  if active then return end
  loadJobSequence = loadJobSequence + 1
  loadedProfileName = nil
  resetQuarryRuntimeState()
end

-- Public API: player actions ----------------------------------------------------------------------

M.acceptContractFromUI = function(index) uiCallbacks.onAcceptContract(index) end
M.declineAllContracts = function() uiCallbacks.onDeclineAll() end
M.abandonContractFromUI = function() uiCallbacks.onAbandonContract() end
M.sendTruckFromUI = function() uiCallbacks.onSendTruck() end
M.finalizeContractFromUI = function() uiCallbacks.onFinalizeContract() end
M.loadMoreFromUI = function() uiCallbacks.onLoadMore() end
M.selectZoneFromUI = function(zoneIndex) uiCallbacks.onSelectZone(zoneIndex) end
M.swapZoneFromUI = function() uiCallbacks.onSwapZone() end
M.setZoneWaypointFromUI = function(zoneTag) uiCallbacks.onSetZoneWaypoint(zoneTag) end

-- The activity host delegates to these functions because building the phone payload
-- also refreshes runtime data and cannot serve as a read-only projection.
M.activity = require('overhaul/jobs/quarry/activity')(M)

-- Game hooks ------------------------------------------------------------------------------------

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onItemDamageCallback = onItemDamageCallback
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onOverhaulModulesActivated = onOverhaulModulesActivated
M.onOverhaulActive = onOverhaulActive

M.requestQuarryState = function() triggerPhoneState() end

return M
