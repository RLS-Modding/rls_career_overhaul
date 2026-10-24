-- Quarry travel, truck arrival, loading and delivery state handlers.
-- The owner supplies live modules and frame inputs to avoid stale reload state.
return function(Config, setCurrentState, spawnOrMoveTruckToZone, handleTruckNudging,
  cleanupAbandonedJob, updateIdle, updateContractSelection)
  local quarrySettings = require("overhaul/jobs/quarry/settings")

  local function updateDrivingToSite(dt, Config, Contracts, Zones, Manager, playerVehicle, playerPosition, settingsPayload, settingsTruck)
    local group = Manager.jobObjects.activeGroup
    if not group or not group.loading then
      Contracts.abandonContract(cleanupAbandonedJob)
      setCurrentState(Config.STATE_IDLE)
      return true
    end
    local targetPosition = Manager.getLoadingZoneTargetPos(group)
    if targetPosition then
      if not core_groundMarkers.getTargetPos() or core_groundMarkers.getTargetPos() ~= targetPosition then
        core_groundMarkers.setPath(targetPosition)
      end
    end
    local hasDesignatedStop = group.stopLocations and #group.stopLocations > 0
    if Manager.jobObjects.truckSpawnQueued or not Manager.jobObjects.truckID then
      if spawnOrMoveTruckToZone(group, false) then
        if hasDesignatedStop then
          setCurrentState(Config.STATE_TRUCK_ARRIVING)
        else
          setCurrentState(Config.STATE_LOADING)
          Manager.truckStoppedInLoading = false
        end
        Manager.deliveryTimer = 0
        Manager.truckStoppedTimer = 0
        Manager.truckLastPosition = nil
        if not hasDesignatedStop then
          core_groundMarkers.setPath(nil)
        end
      end
    end
    if group.loading:containsPoint2D(playerPosition) then
      if not Manager.markerCleared then
        Manager.markerCleared = true
        if #Manager.propQueue == 0 then
          Manager.spawnJobMaterials(Contracts, Zones, playerPosition)
        end
      end
    end
  end

  local function finishTruckArrival(Config, Contracts, Zones, Manager, playerPosition)
    Manager.stopTruck(Manager.jobObjects.truckID)
    Manager.truckStoppedInLoading = true
    if #Manager.propQueue == 0 then
      Manager.spawnJobMaterials(Contracts, Zones, playerPosition)
    end
    ui_message("Truck arrived at loading zone.", 5, "success")
    setCurrentState(Config.STATE_LOADING)
    Manager.deliveryTimer = 0
    Manager.truckStoppedTimer = 0
    Manager.truckLastPosition = nil
    core_groundMarkers.setPath(nil)
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Countdown>3_seconds')
  end

  local function updateTruckArrival(dt, Config, Contracts, Zones, Manager, playerVehicle, playerPosition, settingsPayload, settingsTruck)
    local group = Manager.jobObjects.activeGroup
    if not group or not group.loading then
      Contracts.abandonContract(cleanupAbandonedJob)
      setCurrentState(Config.STATE_IDLE)
      return true
    end
    if Manager.jobObjects.truckID and not Manager.truckStoppedInLoading then
      local truck = be:getObjectByID(Manager.jobObjects.truckID)
      if not truck then
        Contracts.failContract(0, "Truck lost! Contract failed.", "error", Manager.cleanupJob)
        setCurrentState(Config.STATE_IDLE)
        return true
      end
      local hasDesignatedStop = group.stopLocations and #group.stopLocations > 0
      local routingTargetPos = Manager.getLoadingZoneTargetPos(group)
      local stopLocationPos = hasDesignatedStop and group.stopLocations[1] and group.stopLocations[1].pos and vec3(group.stopLocations[1].pos) or nil
      local truckPos = truck:getPosition()
      local arrivalSpeed = quarrySettings.value(settingsTruck, "truck", "arrivalSpeedThreshold")
      if hasDesignatedStop and routingTargetPos then
        local arrivalDist = quarrySettings.value(settingsTruck, "truck", "arrivalDistanceThreshold")
        local arrivalTargetPos = stopLocationPos or routingTargetPos
        local atTarget = (truckPos - arrivalTargetPos):length() < arrivalDist
        if not Manager.jobObjects.loadingZoneTargetPos or (Manager.jobObjects.loadingZoneTargetPos - routingTargetPos):length() > 0.1 then
          Manager.jobObjects.loadingZoneTargetPos = routingTargetPos
          Manager.driveTruckToPoint(Manager.jobObjects.truckID, routingTargetPos)
        end
        if atTarget and truck:getVelocity():length() < arrivalSpeed then
          finishTruckArrival(Config, Contracts, Zones, Manager, playerPosition)
        else
          handleTruckNudging(Manager.jobObjects.truckID, truck, arrivalTargetPos, arrivalDist, atTarget)
        end
      elseif not hasDesignatedStop and group.loading:containsPoint2D(truckPos) and truck:getVelocity():length() < arrivalSpeed then
        finishTruckArrival(Config, Contracts, Zones, Manager, playerPosition)
      end
    end
  end

  local function updateLoading(dt, Config, Contracts, Zones, Manager, playerVehicle, playerPosition, settingsPayload, settingsTruck)
    local group = Manager.jobObjects.activeGroup
    if not group or not group.loading then
      Contracts.abandonContract(cleanupAbandonedJob)
      setCurrentState(Config.STATE_IDLE)
      return true
    end
    Manager.deliveryTimer = 0
    Manager.truckStoppedTimer = 0
    Manager.truckLastPosition = nil
    if Manager.jobObjects.truckID and not Manager.truckStoppedInLoading then
      local truck = be:getObjectByID(Manager.jobObjects.truckID)
      if not truck then
        Contracts.failContract(0, "Truck lost! Contract failed.", "error", Manager.cleanupJob)
        setCurrentState(Config.STATE_IDLE)
        return true
      end
      local arrivalSpeed = quarrySettings.value(settingsTruck, "truck", "arrivalSpeedThreshold")
      local hasDesignatedStop = group.stopLocations and #group.stopLocations > 0
      local routingTargetPos = Manager.getLoadingZoneTargetPos(group)
      local stopLocationPos = hasDesignatedStop and group.stopLocations[1] and group.stopLocations[1].pos and vec3(group.stopLocations[1].pos) or nil
      local truckPos = truck:getPosition()
      local arrivalTargetPos = stopLocationPos or routingTargetPos
      local atTarget = arrivalTargetPos and (truckPos - arrivalTargetPos):length() < (quarrySettings.value(settingsTruck, "truck", "arrivalDistanceThreshold"))
      if hasDesignatedStop and routingTargetPos then
        if not Manager.jobObjects.loadingZoneTargetPos or (Manager.jobObjects.loadingZoneTargetPos - routingTargetPos):length() > 0.1 then
          Manager.jobObjects.loadingZoneTargetPos = routingTargetPos
          Manager.driveTruckToPoint(Manager.jobObjects.truckID, routingTargetPos)
        end
        if atTarget and truck:getVelocity():length() < arrivalSpeed then
          Manager.stopTruck(Manager.jobObjects.truckID)
          Manager.truckStoppedInLoading = true
          if #Manager.propQueue == 0 then
            Manager.spawnJobMaterials(Contracts, Zones, playerPosition)
          end
          ui_message("Truck arrived at loading zone.", 5, "success")
          core_groundMarkers.setPath(nil)
          Engine.Audio.playOnce('AudioGui', 'event:>UI>Countdown>3_seconds')
        else
          handleTruckNudging(Manager.jobObjects.truckID, truck, arrivalTargetPos, quarrySettings.value(settingsTruck, "truck", "arrivalDistanceThreshold"), atTarget)
        end
      elseif not hasDesignatedStop and group.loading:containsPoint2D(truckPos) and truck:getVelocity():length() < arrivalSpeed then
        Manager.stopTruck(Manager.jobObjects.truckID)
        Manager.truckStoppedInLoading = true
        if #Manager.propQueue == 0 then
          Manager.spawnJobMaterials(Contracts, Zones, playerPosition)
        end
        ui_message("Truck arrived at loading zone.", 5, "success")
        core_groundMarkers.setPath(nil)
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Countdown>3_seconds')
      end
    end
  end

  local function tallyDamagedItems(Config, Contracts, Manager, contract, stuckPropIds)
    local contractTypeName = contract.materialTypeName
    if contractTypeName and contract.unitType == "item" and stuckPropIds and #stuckPropIds > 0 then
      local deliveredSet = {}
      for _, id in ipairs(stuckPropIds) do deliveredSet[id] = true end
      if not Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial then
        Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial = {}
      end
      for _, entry in ipairs(Manager.propQueue) do
        if entry.id and deliveredSet[entry.id] and entry.materialType then
          local entryMatConfig = Config.materials and Config.materials[entry.materialType]
          if entryMatConfig and entryMatConfig.typeName == contractTypeName then
            Contracts.ContractSystem.contractProgress.deliveredItems = (Contracts.ContractSystem.contractProgress.deliveredItems or 0) + 1
            Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial[entry.materialType] = (Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial[entry.materialType] or 0) + 1
          end
        end
      end
    end
  end

  local function settleDamagedDelivery(Config, Contracts, Zones, Manager, playerPosition, deliveryTime)
    local contract = Contracts.ContractSystem.activeContract
    if not contract then Manager.cleanupJob(true, Config.STATE_IDLE); setCurrentState(Config.STATE_IDLE); return true end
    local stuckPropIds = Manager.getLoadedPropIdsInTruck(0.1)
    if deliveryTime and deliveryTime >= 30.0 then
      local deliveredMass = Manager.jobObjects.lastDeliveredMass or 0
      local tons = deliveredMass / 1000
      Contracts.ContractSystem.contractProgress.deliveredTons = (Contracts.ContractSystem.contractProgress.deliveredTons or 0) + tons
      Contracts.ContractSystem.contractProgress.deliveryCount = (Contracts.ContractSystem.contractProgress.deliveryCount or 0) + 1
      tallyDamagedItems(Config, Contracts, Manager, contract, stuckPropIds)
    end
    if #stuckPropIds > 0 then
      Manager.despawnPropIds(stuckPropIds, Zones, Contracts, true)
    end
    local deliveredMass = Manager.jobObjects.lastDeliveredMass or 0
    Manager.jobObjects.deliveredPropIds, Manager.jobObjects.currentLoadMass, Manager.jobObjects.lastDeliveredMass = nil, 0, 0
    Manager.deliveryTimer = 0
    Manager.truckStoppedTimer = 0
    Manager.truckLastPosition = nil
    Manager.truckDamage = 0
    Manager.damageCheckQueued = false
    Manager.teleportQueued = false
    if Manager.jobObjects.activeGroup and contract.unitType ~= "item" and deliveredMass > 0 then
      Manager.respawnMassMaterials(Contracts, Zones, deliveredMass)
    end
    if Contracts.checkContractCompletion() then
      if Manager.jobObjects.truckID then
        local obj = be:getObjectByID(Manager.jobObjects.truckID)
        if obj then obj:delete() end
      end
      Manager.jobObjects.truckID, Manager.truckStoppedInLoading, Manager.markerCleared = nil, false, true
      setCurrentState(Config.STATE_AT_QUARRY_DECIDE)
      Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_End_Success')
      ui_message("Contract complete! Ready to finalize.", 6, "success")
    else
      if #Manager.propQueue == 0 then Manager.spawnJobMaterials(Contracts, Zones, playerPosition) end
      local group = Manager.jobObjects.activeGroup
      if group and Manager.jobObjects.truckID then
        local truck = be:getObjectByID(Manager.jobObjects.truckID)
        if truck then
          Manager.stopTruck(Manager.jobObjects.truckID)
          local loadingCenter = vec3(group.loading.center)
          local pos, rot = Manager.calculateSpawnTransformForLocation(vec3(group.spawn.pos), loadingCenter)
          spawn.safeTeleport(truck, pos, rot, nil, nil, nil, true)
          Manager.driveTruckToPoint(Manager.jobObjects.truckID, loadingCenter)
          setCurrentState(Config.STATE_LOADING)
          Manager.truckStoppedInLoading = false
        end
      end
    end
  end

  local function tallyArrivedItems(Config, Contracts, Manager, contract)
    local contractTypeName = contract.materialTypeName
    if contractTypeName and contract.unitType == "item" and Manager.jobObjects.deliveredPropIds then
      local deliveredSet = {}
      for _, id in ipairs(Manager.jobObjects.deliveredPropIds) do deliveredSet[id] = true end
      if not Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial then
        Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial = {}
      end
      for _, entry in ipairs(Manager.propQueue) do
        if entry.id and deliveredSet[entry.id] and entry.materialType then
          local entryMatConfig = Config.materials and Config.materials[entry.materialType]
          if entryMatConfig and entryMatConfig.typeName == contractTypeName then
            Contracts.ContractSystem.contractProgress.deliveredItems = (Contracts.ContractSystem.contractProgress.deliveredItems or 0) + 1
            Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial[entry.materialType] = (Contracts.ContractSystem.contractProgress.deliveredItemsByMaterial[entry.materialType] or 0) + 1
          end
        end
      end
    end
  end

  local function settleArrivedDelivery(Config, Contracts, Zones, Manager, playerPosition)
    -- Arrival spawns materials before completion; damaged recovery waits until the contract remains unfinished.
    -- spawns them only for an unfinished contract. Preserve that difference.
    local contract = Contracts.ContractSystem.activeContract
    if not contract then Manager.cleanupJob(true, Config.STATE_IDLE); setCurrentState(Config.STATE_IDLE); return true end
    local deliveredMass = Manager.jobObjects.lastDeliveredMass or 0
    local tons = deliveredMass / 1000
    Contracts.ContractSystem.contractProgress.deliveredTons = (Contracts.ContractSystem.contractProgress.deliveredTons or 0) + tons
    Contracts.ContractSystem.contractProgress.deliveryCount = (Contracts.ContractSystem.contractProgress.deliveryCount or 0) + 1
    tallyArrivedItems(Config, Contracts, Manager, contract)
    if Manager.jobObjects.deliveredPropIds and #Manager.jobObjects.deliveredPropIds > 0 then
      Manager.despawnPropIds(Manager.jobObjects.deliveredPropIds, Zones, Contracts, true)
    end
    Manager.jobObjects.deliveredPropIds, Manager.jobObjects.currentLoadMass, Manager.jobObjects.lastDeliveredMass = nil, 0, 0
    Manager.deliveryTimer = 0
    Manager.truckStoppedTimer = 0
    Manager.truckLastPosition = nil
    if Manager.jobObjects.activeGroup then
      if contract.unitType ~= "item" and deliveredMass > 0 then
        Manager.respawnMassMaterials(Contracts, Zones, deliveredMass)
      end
      Manager.spawnJobMaterials(Contracts, Zones, playerPosition)
    end
    if Contracts.checkContractCompletion() then
      if Manager.jobObjects.truckID then
        local obj = be:getObjectByID(Manager.jobObjects.truckID)
        if obj then obj:delete() end
      end
      Manager.jobObjects.truckID, Manager.truckStoppedInLoading, Manager.markerCleared = nil, false, true
      setCurrentState(Config.STATE_AT_QUARRY_DECIDE)
      Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_End_Success')
      ui_message("Contract complete! Ready to finalize.", 6, "success")
    else
      Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Mission_End_Success')
      if #Manager.propQueue == 0 then
        if contract.unitType ~= "item" and deliveredMass > 0 then
          Manager.respawnMassMaterials(Contracts, Zones, deliveredMass)
        end
        Manager.spawnJobMaterials(Contracts, Zones, playerPosition)
      end
      local group = Manager.jobObjects.activeGroup
      if group and Manager.jobObjects.truckID then
        local truck = be:getObjectByID(Manager.jobObjects.truckID)
        if truck then
          Manager.stopTruck(Manager.jobObjects.truckID)
          local loadingCenter = vec3(group.loading.center)
          local pos, rot = Manager.calculateSpawnTransformForLocation(vec3(group.spawn.pos), loadingCenter)
          spawn.safeTeleport(truck, pos, rot, nil, nil, nil, true)
          Manager.driveTruckToPoint(Manager.jobObjects.truckID, loadingCenter)
          setCurrentState(Config.STATE_LOADING)
          Manager.truckStoppedInLoading = false
          Manager.deliveryTimer = 0
          Manager.truckStoppedTimer = 0
          Manager.truckLastPosition = nil
        end
      end
    end
  end

  local function updateDelivery(dt, Config, Contracts, Zones, Manager, playerVehicle, playerPosition, settingsPayload, settingsTruck)
    Manager.payloadUpdateTimer = Manager.payloadUpdateTimer + dt
    local payloadInterval = quarrySettings.value(settingsPayload, "payload", "updateInterval")
    if Manager.payloadUpdateTimer >= payloadInterval then
      Manager.calculateItemDamage()
      Manager.processPendingRespawns(dt, Zones, Contracts)
      Manager.payloadUpdateTimer = 0
    end
    local destinationPosition = Manager.jobObjects.deliveryDestination and vec3(Manager.jobObjects.deliveryDestination.pos) or (Manager.jobObjects.activeGroup and Manager.jobObjects.activeGroup.destination and vec3(Manager.jobObjects.activeGroup.destination.pos))
    local movementResult, deliveryTime = Manager.handleTruckMovement(dt, destinationPosition, Contracts)
    if destinationPosition and Manager.jobObjects.truckID then
      local truck = be:getObjectByID(Manager.jobObjects.truckID)
      if truck then
        local arrivalDist = quarrySettings.value(settingsTruck, "truck", "arrivalDistanceThreshold")
        local truckPos = truck:getPosition()
        local atTarget = (truckPos - destinationPosition):length() < arrivalDist
        if not handleTruckNudging(Manager.jobObjects.truckID, truck, destinationPosition, arrivalDist, atTarget) and atTarget and Manager.truckNudging then
          Manager.stopNudging(Manager.jobObjects.truckID)
        end
      end
    end
    if movementResult == "damaged" then
      return settleDamagedDelivery(Config, Contracts, Zones, Manager, playerPosition, deliveryTime)
    elseif movementResult == true then
      return settleArrivedDelivery(Config, Contracts, Zones, Manager, playerPosition)
    end
  end

  -- Build once when the child modules load, never during a frame update.
  return {
    [Config.STATE_IDLE] = updateIdle,
    [Config.STATE_CONTRACT_SELECT] = updateContractSelection,
    [Config.STATE_DRIVING_TO_SITE] = updateDrivingToSite,
    [Config.STATE_TRUCK_ARRIVING] = updateTruckArrival,
    [Config.STATE_LOADING] = updateLoading,
    [Config.STATE_DELIVERING] = updateDelivery,
  }
end
