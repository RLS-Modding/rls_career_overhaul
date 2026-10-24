-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Map-travel restoration owns parking, carried vehicles and hitch retry jobs.
-- Read in order: spots, placement (carriedFrame.lua owns support frames), hitches, arrival jobs, manifests.
local travelPart = {}
local levelData = require('overhaul/lib/world/levelData')
local carriedFrame = require('overhaul/lib/vehicles/carriedFrame')

function travelPart.new(inputs)
  local helpers = {}

  -- Saving the settled pose repeatedly turns normal suspension movement into cumulative load drift.
  function inputs.travel.getCarriedPlacement(inventoryId, parentInventoryId)
    local record = inputs.vehicles[tonumber(inventoryId)]
    local placement = record and record.carriedPlacement
    if placement and placement.parentInventoryId == tonumber(parentInventoryId) then return deepcopy(placement) end
  end

  function inputs.travel.rememberCarriedPlacement(relation, staged)
    local id, parentId = tonumber(relation.inventoryId), tonumber(relation.parentInventoryId)
    local record = id and inputs.vehicles[id]
    if not record or not parentId or type(relation.offset) ~= 'table' then return end
    local previous = inputs.travel.getCarriedPlacement(id, parentId)
    if previous and (previous.staged or not staged) then return previous end
    record.carriedPlacement = {parentInventoryId=parentId, offset=deepcopy(relation.offset),
      support=deepcopy(relation.support), staged=staged == true}
    return deepcopy(record.carriedPlacement)
  end

  function inputs.travel.clearCarriedPlacement(inventoryId)
    local record = inputs.vehicles[tonumber(inventoryId)]
    if record then record.carriedPlacement = nil end
  end

  -- Spot selection --------------------------------------------------------------------------------

  inputs.travel.spotTypeAliases = {
    {token = "trailer", vehicleType = "trailer"},
    {token = "truck", vehicleType = "truck"},
    {token = "semi", vehicleType = "truck"},
    {token = "pickup", vehicleType = "truck"},
    {token = "bus", vehicleType = "bus"},
    {token = "coach", vehicleType = "bus"},
    {token = "van", vehicleType = "van"},
    {token = "motorcycle", vehicleType = "motorcycle"},
    {token = "bike", vehicleType = "motorcycle"},
    {token = "car", vehicleType = "car"},
    {token = "suv", vehicleType = "car"},
  }

  function inputs.travel.getVehicleType(vehId, inventoryId)
    local inventoryVehicle = inputs.vehicles[inventoryId] or {}
    local vehicleData = core_vehicle_manager.getVehicleData(vehId)
    local config = vehicleData and vehicleData.config or inventoryVehicle.config or {}
    local modelName = inventoryVehicle.model
    local vehicle = getObjectByID(vehId)
    if vehicle and vehicle.JBeam then modelName = vehicle.JBeam end

    local configInfo
    if config.partConfigFilename then
      local _, configName = path.splitWithoutExt(config.partConfigFilename)
      configInfo = core_vehicles.getConfig(modelName, configName)
    end
    local rawType = configInfo and configInfo.aggregates and configInfo.aggregates.Type
      and next(configInfo.aggregates.Type) or nil
    if not rawType then
      local model = core_vehicles.getModel(modelName)
      rawType = model and model.model and model.model.Type or nil
    end

    local normalized = tostring(rawType or ""):lower()
    for _, alias in ipairs(inputs.travel.spotTypeAliases) do
      if normalized:find(alias.token, 1, true) then return alias.vehicleType end
    end
    return nil
  end

  function inputs.travel.getSpotType(spot)
    local fields = spot.customFields or {}
    local vehicleType = (fields.values and fields.values.arrivalVehicleType)
      or (fields.strings and fields.strings.arrivalVehicleType)
    if not vehicleType or vehicleType == 'any' then return nil end
    return vehicleType
  end

  function inputs.travel.getSpots(levelName)
    local spots = {}
    local sitesPath = levelData.assetPath(levelName, 'travel.sites.json')
    if sitesPath and FS:fileExists(sitesPath) then
      local ok, sites = pcall(gameplay_sites_sitesManager.loadSites, sitesPath, true, true)
      local source = ok and sites and sites.parkingSpots and (sites.parkingSpots.sorted or sites.parkingSpots.objects)
      for _, spot in pairs(source or {}) do
        if spot and spot.pos and not spot.missing then spots[#spots + 1] = spot end
      end
    end
    table.sort(spots, function(a, b)
      return tostring(a.name or a.id or "") < tostring(b.name or b.id or "")
    end)
    return #spots > 0 and spots or nil
  end

  function inputs.travel.spotSizeScore(spot)
    local scale = spot.scl or {}
    return math.abs(tonumber(scale.x) or 0) * math.abs(tonumber(scale.y) or 0)
  end

  -- 0 for an exact type match, 1 for an untyped spot, nil when the spot is reserved for another type.
  local function spotTypeScore(spot, vehicleType)
    local spotType = inputs.travel.getSpotType(spot)
    if spotType == vehicleType and vehicleType then return 0 end
    if not spotType then return 1 end
    return nil
  end

  local function spotFitsVehicle(spot, vehId)
    if not spot.vehicleFits then return true end
    local ok, result = pcall(function() return spot:vehicleFits(vehId) end)
    return ok and result == true
  end

  -- Best spot first by fit, then by type match, then by the tightest fitting (or roomiest misfit) size.
  function inputs.travel.selectSpot(spots, usedSpots, vehId, inventoryId)
    if not spots or #spots == 0 then return nil end
    local vehicleType = inputs.travel.getVehicleType(vehId, inventoryId)
    local bestSpot, bestFitScore, bestTypeScore, bestSize
    for _, spot in ipairs(spots or {}) do
      local typeScore = not usedSpots[spot] and spotTypeScore(spot, vehicleType) or nil
      if typeScore then
        local fits = spotFitsVehicle(spot, vehId)
        local fitScore = fits and 0 or 1
        local size = inputs.travel.spotSizeScore(spot)
        local sizeIsBetter = bestSize == nil
          or (fits and size < bestSize)
          or (not fits and size > bestSize)
        if not bestSpot
            or fitScore < bestFitScore
            or (fitScore == bestFitScore and typeScore < bestTypeScore)
            or (fitScore == bestFitScore and typeScore == bestTypeScore and sizeIsBetter) then
          bestSpot = spot
          bestFitScore = fitScore
          bestTypeScore = typeScore
          bestSize = size
        end
      end
    end
    return bestSpot
  end

  -- Placement -------------------------------------------------------------------------------------

  function inputs.travel.placeVehicle(veh, spot, inventoryId, preserveShape)
    if not veh or not spot or not spot.moveResetVehicleTo then return false end
    local resetVehicle
    if preserveShape then resetVehicle = false end
    local ok, placed = pcall(function()
      return spot:moveResetVehicleTo(veh:getID(), nil, false, nil, nil, true, nil, resetVehicle)
    end)
    ok = ok and (type(placed) ~= 'boolean' or placed)
    if ok and inputs.travel.getVehicleType(veh:getID(), inventoryId) == "trailer" then
      local vehId = veh:getID()
      local levelName = getCurrentLevelIdentifier()
      core_jobsystem.create(function(job)
        job.sleep(0.25)
        if overhaul_career_garage_inventory == inputs.M and getCurrentLevelIdentifier() == levelName
            and inputs.inventoryIdToVehId[inventoryId] == vehId then
          local trailer = getObjectByID(vehId)
          if trailer then
            trailer:autoplace(false)
            inputs.travel.finishVehiclePlacement(trailer, inventoryId)
          end
        end
      end)
      return true, true
    end
    return ok
  end

  function inputs.travel.finishVehiclePlacement(veh, inventoryId)
    if inputs.M.completeVehiclePlacement then inputs.M.completeVehiclePlacement(inventoryId, veh:getID()) end
  end

  function inputs.travel.discardVehicle(inventoryId)
    if inputs.inventoryIdToVehId[inventoryId] then
      helpers.removeVehicleObject(inventoryId, true)
    end
  end

  function inputs.travel.applyTravelBrakeState(veh, relation)
    if not veh or not relation then return end
    local brake = clamp(tonumber(relation.brake) or 0, 0, 1)
    local parkingbrake = clamp(tonumber(relation.parkingbrake) or 0, 0, 1)
    veh:queueLuaCommand(string.format(
      "input.event('brake', %.6f, 1); input.event('parkingbrake', %.6f, 1)",
      brake, parkingbrake))
  end

  function inputs.travel.placeCarriedVehicle(veh, carrier, relation)
    local offset = relation and relation.offset
    if not veh or not carrier or type(offset) ~= "table" then return false end
    local ok, placed = pcall(function()
      local transform = carriedFrame.transform(carrier, relation)
      if not transform then return false end
      veh:setTransform(transform)
      veh:resetBrokenFlexMesh()
      return true
    end)
    if ok and placed then inputs.travel.applyTravelBrakeState(veh, relation) end
    return ok and placed == true
  end

  -- Hitch restoration -----------------------------------------------------------------------------

  function inputs.travel.resolveHitch(veh, nodeName)
    local data = core_vehicle_manager.getVehicleData(veh:getID())
    for _, node in pairs(data and data.vdata and data.vdata.nodes or {}) do
      if node.name == nodeName or (type(nodeName) == "number" and node.cid == nodeName) then
        local offsets = core_vehicles.vehsCouplerOffset[veh:getID()]
        return node.cid, offsets and offsets[node.cid], node.couplerTag
      end
    end
  end

  function inputs.travel.hitchConnected(parentId, childId, parentNode, childNode)
    for _, connection in ipairs(core_vehicles.attachedCouplers or {}) do
      if (connection[1] == parentId and connection[2] == childId
          and connection[3] == parentNode and connection[4] == childNode)
          or (connection[2] == parentId and connection[1] == childId
          and connection[4] == parentNode and connection[3] == childNode) then
        return true
      end
    end
    return false
  end

  function inputs.travel.isRestoreActive(restoreState)
    return inputs.travel.activeRestore == restoreState and overhaul_career_garage_inventory == inputs.M
      and getCurrentLevelIdentifier() == restoreState.levelName
  end

  function inputs.travel.waitForPhysics(job, restoreState)
    while simTimeAuthority.getPause() do
      if not inputs.travel.isRestoreActive(restoreState) then return false end
      job.sleep(0.1)
    end
    return inputs.travel.isRestoreActive(restoreState)
  end

  function inputs.travel.restoreHitch(veh, carrier, relation, job, restoreState)
    local childId, parentId = veh:getID(), carrier:getID()
    local function valid()
      return inputs.travel.isRestoreActive(restoreState)
        and inputs.inventoryIdToVehId[relation.inventoryId] == childId
        and inputs.inventoryIdToVehId[relation.parentInventoryId] == parentId
        and getObjectByID(childId) and getObjectByID(parentId)
    end
    for _ = 1, 100 do
      if not valid() then return false end
      if veh:isReady() and carrier:isReady() then break end
      job.sleep(0.05)
    end
    if not valid() or not veh:isReady() or not carrier:isReady() then return false end

    local parentNode, parentOffset, tag = inputs.travel.resolveHitch(carrier, relation.parentNode)
    local childNode, childOffset = inputs.travel.resolveHitch(veh, relation.node)
    if not parentOffset or not childOffset or not tag then return false end
    if inputs.travel.hitchConnected(parentId, childId, parentNode, childNode) then return true end
    local ok = pcall(function()
      local rotation = MatrixF(true)
      local offset = relation.offset
      rotation:setFromEuler(vec3(offset.rx or 0, offset.ry or 0, offset.rz or 0))
      veh:setTransform(spawn.calculateRelativeVehiclePlacement(
        carrier:getRefNodeMatrix(), parentOffset, childOffset, rotation))
      veh:queueLuaCommand('obj:requestReset(RESET_PHYSICS)')
      veh:resetBrokenFlexMesh()
    end)
    if not ok then return false end
    job.sleep(0.05)
    if not valid() then return false end
    local autoCouple = core_vehicles.couplerTagsOptions[tag] == "autoCouple"
    if autoCouple then
      carrier:queueLuaCommand(string.format('beamstate.activateAutoCoupling(%q)', tag))
    end
    for _ = 1, 60 do
      if not inputs.travel.waitForPhysics(job, restoreState) or not valid() then return false end
      if inputs.travel.hitchConnected(parentId, childId, parentNode, childNode) then return true end
      job.sleep(0.05)
    end
    if valid() and inputs.travel.hitchConnected(parentId, childId, parentNode, childNode) then return true end
    if valid() then
      if autoCouple then carrier:queueLuaCommand('beamstate.disableAutoCoupling()') end
      carrier:queueLuaCommand(string.format('obj:detachCoupler(%d, 0)', parentNode))
    end
    return false
  end

  -- Spawning a manifest tree ----------------------------------------------------------------------

  local RESTORE_ATTEMPT_LIMIT = 2
  local CARRIED_SETTLE_SECONDS = 0.35
  local CARRIED_LOADING_TAG = "overhaulCarriedRestore"
  -- A stuck restore must not trap the player behind the loading screen.
  local CARRIED_LOADING_MAX_SECONDS = 45
  local VEHICLE_READY_ATTEMPTS = 100
  -- VE setup plus the bounded actuator operation can outlast the engine object's initial readiness window.
  local RESTORE_READY_ATTEMPTS = 1200
  local VEHICLE_READY_INTERVAL_SECONDS = 0.05
  local settleRestoreProgress

  local function savedLocationOf(restoreState, inventoryId)
    return restoreState.savedLocations
      and (restoreState.savedLocations[tostring(inventoryId)] or restoreState.savedLocations[inventoryId])
  end

  local function deferCarriedNode(restoreState, node, relation, rootIsCurrent, inventoryId)
    if restoreState.pendingCarriedIds[inventoryId] then return end
    restoreState.pendingCarriedIds[inventoryId] = true
    restoreState.pendingCarried[#restoreState.pendingCarried + 1] = {
      node = node,
      relation = relation,
      rootIsCurrent = rootIsCurrent,
    }
  end

  local function spawnChildren(node, spots, usedSpots, restoreState, carriedById)
    for _, child in ipairs(node.children or {}) do
      inputs.travel.spawnNode(child, spots, usedSpots, false, restoreState, carriedById)
    end
  end

  local function teleportVehicle(veh, destination, preserveShape)
    if not destination then return false end
    local resetVehicle
    if preserveShape then resetVehicle = false end
    local ok, placed = pcall(spawn.safeTeleport, veh, destination.pos, destination.rot, nil, nil, nil, nil,
      resetVehicle)
    return ok and (type(placed) ~= 'boolean' or placed)
  end

  -- The entered vehicle arrives at the gate; other groups can use optional parking for more room.
  local function placeRestoredVehicle(veh, inventoryId, location, spots, usedSpots, rootIsCurrent, restoreState, preserveShape)
    if location then return teleportVehicle(veh, {pos = vec3(location.pos), rot = quat(location.rot)}, preserveShape) end
    local arrival = not restoreState.sessionRestore and (restoreState.arrival or levelData.recoverySpawn(restoreState.levelName))
    if rootIsCurrent and teleportVehicle(veh, arrival, preserveShape) then return true end
    local spot = not restoreState.sessionRestore and inputs.travel.selectSpot(spots, usedSpots, veh:getID(), inventoryId)
    if spot then
      local placed, deferred = inputs.travel.placeVehicle(veh, spot, inventoryId, preserveShape)
      if placed then usedSpots[spot] = true; return true, deferred end
    end
    return teleportVehicle(veh, arrival, preserveShape)
  end

  function inputs.travel.spawnNode(node, spots, usedSpots, rootIsCurrent, restoreState, carriedById, forceIndependent)
    local inventoryId = tonumber(node and node.inventoryId)
    if not inventoryId or not inputs.vehicles[inventoryId] then return nil end
    if restoreState.sessionRestore and not savedLocationOf(restoreState, inventoryId) then return nil end
    local relation = carriedById and carriedById[inventoryId]
    if relation and not forceIndependent then
      deferCarriedNode(restoreState, node, relation, rootIsCurrent, inventoryId)
      return nil
    end

    local location = savedLocationOf(restoreState, inventoryId)
    local arrival = restoreState.arrival or levelData.recoverySpawn(restoreState.levelName)
    local spawnAt = location and location.pos and {pos = vec3(location.pos), rot = location.rot and quat(location.rot) or nil}
      or (rootIsCurrent and arrival) or (spots and spots[1]) or arrival
    if not spawnAt then
      restoreState.spawnFailedIds[inventoryId] = true
      spawnChildren(node, spots, usedSpots, restoreState, carriedById)
      return nil
    end
    local existingVehId = inputs.inventoryIdToVehId[inventoryId]
    local veh = existingVehId and getObjectByID(existingVehId) or helpers.spawnVehicle(inventoryId, nil, nil, spawnAt, true)
    if not veh then
      restoreState.spawnFailedIds[inventoryId] = true
      spawnChildren(node, spots, usedSpots, restoreState, carriedById)
      return nil
    end
    if existingVehId and inputs.M.deferVehiclePlacement then inputs.M.deferVehiclePlacement(inventoryId, veh:getID()) end

    local placed, deferred = placeRestoredVehicle(veh, inventoryId, location, spots, usedSpots, rootIsCurrent, restoreState, forceIndependent)
    if placed then
      if not deferred then inputs.travel.finishVehiclePlacement(veh, inventoryId) end
      restoreState.placedInventoryIds[inventoryId] = true
      if location then inputs.travel.applyTravelBrakeState(veh, node) end
      if relation and not relation.coupled then inputs.travel.applyTravelBrakeState(veh, relation) end
    else
      restoreState.spawnFailedIds[inventoryId] = true
      inputs.travel.discardVehicle(inventoryId)
    end
    spawnChildren(node, spots, usedSpots, restoreState, carriedById)
    return placed and veh or nil
  end

  -- Carried vehicles ------------------------------------------------------------------------------

  local function acknowledgeVehicleCommands(veh, inventoryId, job, restoreState)
    local acknowledged = not core_vehicleBridge
    if core_vehicleBridge then
      core_vehicleBridge.requestValue(veh, function() acknowledged = true end, 'ping')
    end
    for _ = 1, VEHICLE_READY_ATTEMPTS do
      if not inputs.travel.waitForPhysics(job, restoreState) then return false, true end
      if inputs.inventoryIdToVehId[inventoryId] ~= veh:getID() then return false end
      if acknowledged then
        job.sleep(CARRIED_SETTLE_SECONDS)
        return inputs.travel.isRestoreActive(restoreState)
      end
      job.sleep(VEHICLE_READY_INTERVAL_SECONDS)
    end
    return false
  end

  -- A ready engine object can still have queued condition, damage and hydro restoration.
  local function waitForRestoredVehicle(veh, inventoryId, job, restoreState, beforePlacement)
    if not veh then return false end
    local vehId = veh:getID()
    for _ = 1, RESTORE_READY_ATTEMPTS do
      if not inputs.travel.waitForPhysics(job, restoreState) then return false, true end
      if inputs.inventoryIdToVehId[inventoryId] ~= vehId or not getObjectByID(vehId) then return false end
      local tracker = inputs.M.getSpawnReadiness and inputs.M.getSpawnReadiness()
      local attempt = tracker and tracker.get(inventoryId)
      local states = attempt and attempt.states
      if states and states.damageRestored == 'mechanismFailed' then return false end
      local ready = attempt and attempt.complete
      if beforePlacement and states then
        ready = states.bound and states.conditionsInitialized and states.veAcknowledged and states.aiConfigured
      end
      local boundId = attempt and (attempt.vehId or (states and states.bound))
      if veh:isReady() and (not attempt or (boundId == vehId and ready and not attempt.closed)) then
        return acknowledgeVehicleCommands(veh, inventoryId, job, restoreState)
      end
      job.sleep(VEHICLE_READY_INTERVAL_SECONDS)
    end
    return false
  end

  local function placePendingCarriedVehicle(veh, carrier, relation, job, restoreState)
    if not veh or not carrier then return false end
    if not relation.coupled then return inputs.travel.placeCarriedVehicle(veh, carrier, relation) end
    local ok, result = pcall(inputs.travel.restoreHitch, veh, carrier, relation, job, restoreState)
    if not ok then log("W", "career.inventory", "Map travel hitch restore: " .. tostring(result)) end
    if not inputs.travel.isRestoreActive(restoreState) then return false, true end
    return ok and result
  end

  -- A carried vehicle that could not be hitched or placed is spawned on its own instead.
  local function respawnCarriedIndependently(pending, veh, spots, usedSpots, restoreState, carriedById, inventoryId, job)
    if not veh then
      restoreState.spawnFailedIds[inventoryId] = true
    end
    if pending.relation.coupled then
      log("W", "career.inventory", "Map travel: hitch restore failed for " .. inventoryId .. "; using a separate spot")
    end
    inputs.travel.spawnNode(pending.node, spots, usedSpots, pending.rootIsCurrent, restoreState, carriedById, true)
    if job then
      job.sleep(CARRIED_SETTLE_SECONDS)
      if not inputs.travel.isRestoreActive(restoreState) then return nil end
    end
    return true
  end

  -- Returns true when the vehicle was handled, false when its carrier is not placed yet, nil when the restore was interrupted.
  local function restorePendingCarriedVehicle(index, spots, usedSpots, restoreState, carriedById, job)
    local pending = restoreState.pendingCarried[index]
    local relation = pending.relation
    local inventoryId = tonumber(pending.node.inventoryId)
    local parentInventoryId = tonumber(relation.parentInventoryId)
    if not restoreState.placedInventoryIds[parentInventoryId] then return false end
    local carrierVehId = inputs.inventoryIdToVehId[parentInventoryId]
    local carrier = carrierVehId and getObjectByID(carrierVehId) or nil
    local ready, interrupted = waitForRestoredVehicle(carrier, parentInventoryId, job, restoreState)
    if interrupted or not inputs.travel.isRestoreActive(restoreState) then return nil end
    local existingVehId = inputs.inventoryIdToVehId[inventoryId]
    -- Safe spawning at the local arrival lets the engine find clearance, without a player/garage fallback.
    local spawnAt = savedLocationOf(restoreState, inventoryId) or restoreState.arrival or (spots and spots[1])
    local veh = existingVehId and getObjectByID(existingVehId) or (spawnAt and helpers.spawnVehicle(inventoryId, nil, nil, spawnAt, true))
    if existingVehId and veh and inputs.M.deferVehiclePlacement then inputs.M.deferVehiclePlacement(inventoryId, veh:getID()) end
    local childReady, childInterrupted = waitForRestoredVehicle(veh, inventoryId, job, restoreState, true)
    if childInterrupted or not inputs.travel.isRestoreActive(restoreState) then return nil end
    if inputs.inventoryIdToVehId[parentInventoryId] ~= carrierVehId then return nil end
    local placed
    if ready and childReady then
      placed, interrupted = placePendingCarriedVehicle(veh, carrier, relation, job, restoreState)
    end
    if interrupted then return nil end
    if not placed then
      table.remove(restoreState.pendingCarried, index)
      return respawnCarriedIndependently(pending, veh, spots, usedSpots, restoreState, carriedById, inventoryId, job)
    end
    inputs.travel.finishVehiclePlacement(veh, inventoryId)
    local restored, restoreInterrupted = waitForRestoredVehicle(veh, inventoryId, job, restoreState)
    if restoreInterrupted or not inputs.travel.isRestoreActive(restoreState) then return nil end
    if not restored then
      table.remove(restoreState.pendingCarried, index)
      return respawnCarriedIndependently(pending, veh, spots, usedSpots, restoreState, carriedById, inventoryId, job)
    end
    job.sleep(CARRIED_SETTLE_SECONDS)
    if not inputs.travel.isRestoreActive(restoreState) then return nil end
    if inputs.inventoryIdToVehId[parentInventoryId] ~= carrierVehId
        or inputs.inventoryIdToVehId[inventoryId] ~= veh:getID() then return nil end
    table.remove(restoreState.pendingCarried, index)
    restoreState.placedInventoryIds[inventoryId] = true
    spawnChildren(pending.node, spots, usedSpots, restoreState, carriedById)
    return true
  end

  function inputs.travel.restoreCarriedVehicles(spots, usedSpots, restoreState, carriedById, job)
    while #restoreState.pendingCarried > 0 do
      if job and not inputs.travel.isRestoreActive(restoreState) then return end
      local madeProgress = false
      for index = #restoreState.pendingCarried, 1, -1 do
        local restored = restorePendingCarriedVehicle(index, spots, usedSpots, restoreState, carriedById, job)
        if restored == nil then return end
        if restored then
          madeProgress = true
          settleRestoreProgress(restoreState)
        end
      end
      if not madeProgress then
        local pending = table.remove(restoreState.pendingCarried, 1)
        inputs.travel.spawnNode(pending.node, spots, usedSpots, pending.rootIsCurrent, restoreState, carriedById, true)
        if job then
          job.sleep(CARRIED_SETTLE_SECONDS)
          if not inputs.travel.isRestoreActive(restoreState) then return end
        end
      end
    end
    table.clear(restoreState.pendingCarried)
    table.clear(restoreState.pendingCarriedIds)
  end

  -- Manifest restoration --------------------------------------------------------------------------

  local function finishPendingRestore()
    inputs.travel.pending = nil
    inputs.travel.previousArrival = nil
    inputs.travel.restoreAttempts = 0
  end

  local function isRestorableManifest(manifest, justSwitched, levelName)
    return type(manifest) == "table" and (justSwitched or manifest.sessionRestore or manifest.arrivalPending)
      and (manifest.version == 1 or manifest.version == 2)
      and manifest.destination == levelName and type(manifest.groups) == "table"
  end

  -- Local world parking and persistent vehicles share the same ordered restoration owner.
  local function addPersistentVehiclesToManifest(manifest)
    local seen = {}
    local function visit(node)
      seen[tonumber(node.inventoryId)] = true
      for _, child in ipairs(node.children or {}) do visit(child) end
    end
    for _, group in ipairs(manifest.groups) do visit(group.tree) end
    local employment = overhaul_career_work_employment
    for id, location in pairs(inputs.state.loadedVehiclesLocations or {}) do
      local info = inputs.vehicles[id]
      local persistentVehicle = info and (info.logisticsInUse or info.brokerRentalId or info.brokerJobId)
      local parkedHere = location.worldLevel == manifest.destination
      if not seen[id] and (parkedHere or persistentVehicle or (employment and employment.shouldPersistVehicle and employment.shouldPersistVehicle(id))) then
        manifest.groups[#manifest.groups + 1] = {rootInventoryId = id, tree = {inventoryId = id, children = {}}}
        manifest.savedLocations = manifest.savedLocations or {}
        manifest.savedLocations[tostring(id)] = location
        seen[id] = true
        local placement = info and info.carriedPlacement
        local parentLocation = placement and inputs.state.loadedVehiclesLocations[placement.parentInventoryId]
        if parkedHere and parentLocation and parentLocation.worldLevel == manifest.destination then
          manifest.carriedVehicles = manifest.carriedVehicles or {}
          local relation = deepcopy(placement)
          relation.inventoryId = id
          manifest.carriedVehicles[#manifest.carriedVehicles + 1] = relation
        end
      end
    end
  end

  -- Both coupled trees and manually carried roots describe the same placement dependency.
  local function collectCarriedRelations(manifest, carriedById)
    local function collectHitches(node, parentId)
      if not node then return end
      local id = tonumber(node.inventoryId)
      if id and parentId and node.parentNode ~= nil and node.node ~= nil
          and type(node.couplerOffset) == "table" then
        carriedById[id] = {
          inventoryId = id, parentInventoryId = parentId,
          parentNode = node.parentNode, node = node.node,
          offset = node.couplerOffset, coupled = true,
          brake = node.brake, parkingbrake = node.parkingbrake,
        }
      end
      for _, child in ipairs(node.children or {}) do collectHitches(child, id) end
    end
    for _, group in ipairs(manifest.groups) do collectHitches(group.tree) end
    for _, relation in ipairs(manifest.carriedVehicles or {}) do
      local inventoryId = tonumber(relation and relation.inventoryId)
      local parentInventoryId = tonumber(relation and relation.parentInventoryId)
      if inventoryId and parentInventoryId and inventoryId ~= parentInventoryId then
        carriedById[inventoryId] = relation
      end
    end
  end

  local function copyFields(value)
    local result = {}
    for key, field in pairs(value or {}) do result[key] = field end
    return result
  end

  local function projectGroups(sourceGroups, keepInventoryId)
    local groups, retainedIds = {}, {}
    local function retain(node, parentRetained)
      local inventoryId = tonumber(node and node.inventoryId)
      if not inventoryId then return nil end
      local keep = keepInventoryId(inventoryId)
      local tree = keep and copyFields(node) or nil
      local children = {}
      if keep then retainedIds[inventoryId] = true end
      for _, child in ipairs(node.children or {}) do
        local retained = retain(child, keep)
        if retained then children[#children + 1] = retained end
      end
      if not tree then return nil end
      tree.children = children
      if not parentRetained then
        tree.parentNode, tree.node, tree.couplerOffset, tree.coupledParentInventoryId = nil, nil, nil, nil
        groups[#groups + 1] = {rootInventoryId = inventoryId, tree = tree}
        return nil
      end
      return tree
    end
    for _, group in ipairs(sourceGroups) do retain(group.tree, false) end
    return groups, retainedIds
  end

  -- Completed placements leave pending work immediately; promoted children no longer depend on a completed carrier.
  settleRestoreProgress = function(restoreState)
    local manifest = restoreState.manifest
    local groups, outstanding = projectGroups(manifest.groups, function(inventoryId)
      return inputs.vehicles[inventoryId] and not restoreState.placedInventoryIds[inventoryId]
    end)
    if #groups == 0 then finishPendingRestore(); return end
    local pending = copyFields(manifest)
    pending.groups, pending.carriedVehicles, pending.savedLocations = groups, {}, {}
    pending.brakeStates = nil
    local hasArrival = false
    for inventoryId in pairs(outstanding) do
      local location = savedLocationOf(restoreState, inventoryId)
      if location then pending.savedLocations[tostring(inventoryId)] = location else hasArrival = true end
    end
    for _, relation in ipairs(manifest.carriedVehicles or {}) do
      if outstanding[tonumber(relation.inventoryId)] and (outstanding[tonumber(relation.parentInventoryId)]
          or inputs.inventoryIdToVehId[tonumber(relation.parentInventoryId)]) then
        pending.carriedVehicles[#pending.carriedVehicles + 1] = relation
      end
    end
    pending.sessionRestore, pending.arrivalPending = not hasArrival, hasArrival
    if not outstanding[tonumber(pending.currentInventoryId)] then pending.currentInventoryId = nil end
    inputs.travel.pending = pending
    for inventoryId in pairs(restoreState.placedInventoryIds) do
      if inputs.state.loadedVehiclesLocations then inputs.state.loadedVehiclesLocations[inventoryId] = nil end
    end
  end

  -- A destination save contains normal world positions as well as unfinished arrivals.
  local function mergeSavedSession(manifest)
    local session = inputs.travel.savedSession
    if not session then return manifest end
    inputs.travel.savedSession = nil
    local merged, seen = copyFields(manifest), {}
    merged.groups = {}
    local function visit(node)
      seen[tonumber(node.inventoryId)] = true
      for _, child in ipairs(node.children or {}) do visit(child) end
    end
    for _, group in ipairs(manifest.groups) do merged.groups[#merged.groups + 1] = group; visit(group.tree) end
    local sessionGroups = projectGroups(session.groups or {}, function(inventoryId)
      if seen[inventoryId] then return false end
      seen[inventoryId] = true
      return true
    end)
    for _, group in ipairs(sessionGroups) do merged.groups[#merged.groups + 1] = group end
    merged.savedLocations = copyFields(manifest.savedLocations)
    for _, source in ipairs({session.savedLocations or {}, inputs.state.loadedVehiclesLocations or {}}) do
      for inventoryId, location in pairs(source) do
        local id = tonumber(inventoryId)
        merged.savedLocations[tostring(id)] = location
        if not seen[id] then
          merged.groups[#merged.groups + 1] = {rootInventoryId = id, tree = {inventoryId = id, children = {}}}
          seen[id] = true
        end
      end
    end
    merged.carriedVehicles = {}
    for _, source in ipairs({manifest.carriedVehicles or {}, session.carriedVehicles or {}}) do
      for _, relation in ipairs(source) do merged.carriedVehicles[#merged.carriedVehicles + 1] = relation end
    end
    merged.currentInventoryId, merged.walking = session.currentInventoryId, session.walking
    return merged
  end

  -- Keeps the load's loading screen up until carried vehicles sit on their carriers, so they are never seen moving there.
  local function holdLoadingScreen(restoreState)
    if not core_gamestate.loading() then return end
    restoreState.holdsLoadingScreen = true
    core_gamestate.requestEnterLoadingScreen(CARRIED_LOADING_TAG)
    core_jobsystem.create(function(job)
      job.sleep(CARRIED_LOADING_MAX_SECONDS)
      if restoreState.holdsLoadingScreen then
        log("W", "career.inventory", "Carried vehicle restore is still running; releasing the loading screen")
        inputs.travel.releaseLoadingScreen(restoreState)
      end
    end)
  end

  function inputs.travel.releaseLoadingScreen(restoreState)
    if not restoreState.holdsLoadingScreen then return end
    restoreState.holdsLoadingScreen = nil
    if core_gamestate.getLoadingStatus(CARRIED_LOADING_TAG) then
      core_gamestate.requestExitLoadingScreen(CARRIED_LOADING_TAG)
    end
  end

  -- One arrival job owns readiness, relative placement and settlement for every carried vehicle.
  local function startCarriedRestoreJob(restoreState, spots, usedSpots, carriedById)
    inputs.travel.activeRestore = restoreState
    core_jobsystem.create(function(job)
      job.setExitCallback(function()
        if inputs.travel.activeRestore == restoreState then inputs.travel.activeRestore = nil end
        inputs.travel.releaseLoadingScreen(restoreState)
      end)
      if not inputs.travel.waitForPhysics(job, restoreState) then return end
      job.sleep(CARRIED_SETTLE_SECONDS)
      if not inputs.travel.isRestoreActive(restoreState) then return end
      inputs.travel.restoreCarriedVehicles(spots, usedSpots, restoreState, carriedById, job)
      if inputs.travel.activeRestore ~= restoreState then return end
      inputs.travel.activeRestore = nil
      settleRestoreProgress(restoreState)
    end)
    holdLoadingScreen(restoreState)
  end

  function inputs.travel.restore(levelName, justSwitched)
    if inputs.travel.activeRestore then return true end
    local manifest = inputs.travel.pending
    if not isRestorableManifest(manifest, justSwitched, levelName) then return false end
    local newArrival = not manifest.sessionRestore and not manifest.arrivalPending
    if not newArrival and not inputs.travel.savedSession and next(inputs.state.loadedVehiclesLocations or {}) then
      local session = {groups = {}, savedLocations = {}, currentInventoryId = inputs.state.vehicleToEnterId,
        walking = inputs.state.unicycleSavedPosition ~= nil}
      for inventoryId, location in pairs(inputs.state.loadedVehiclesLocations) do
        session.groups[#session.groups + 1] = {tree = {inventoryId = inventoryId, children = {}}}
        session.savedLocations[tostring(inventoryId)] = location
      end
      inputs.travel.savedSession = session
    end
    local restoringSession = inputs.travel.savedSession ~= nil or manifest.sessionRestore
    manifest = mergeSavedSession(manifest)
    for _, relation in ipairs(manifest.carriedVehicles or {}) do
      inputs.travel.rememberCarriedPlacement(relation, relation.staged or not manifest.sessionRestore)
    end
    if newArrival then
      local localParking = {}
      for id, location in pairs(inputs.state.loadedVehiclesLocations or {}) do
        if location.worldLevel == levelName then localParking[id] = location end
      end
      inputs.state.loadedVehiclesLocations = next(localParking) and localParking or nil
    end

    -- A session saved on foot restores on foot rather than entering its last vehicle.
    if newArrival or (restoringSession and inputs.travel.restoreAttempts == 0) then
      inputs.state.vehicleToEnterId = not manifest.walking and tonumber(manifest.currentInventoryId) or nil
    end
    addPersistentVehiclesToManifest(manifest)
    if not manifest.sessionRestore then manifest.arrivalPending = true end
    if newArrival then inputs.state.unicycleSavedPosition = nil end
    local arrival = not manifest.sessionRestore and levelData.recoverySpawn(levelName)
    local spots = manifest.sessionRestore and {} or inputs.travel.getSpots(levelName) or {}

    inputs.travel.restoreAttempts = inputs.travel.restoreAttempts + 1
    local usedSpots = {}
    local carriedById = {}
    collectCarriedRelations(manifest, carriedById)
    local restoreState = {
      manifest = manifest,
      sessionRestore = manifest.sessionRestore,
      savedLocations = manifest.savedLocations,
      levelName = levelName,
      arrival = arrival,
      spawnFailedIds = {},
      placedInventoryIds = {},
      pendingCarried = {},
      pendingCarriedIds = {},
    }
    local included = {}
    local function include(node)
      included[tonumber(node.inventoryId)] = true
      for _, child in ipairs(node.children or {}) do include(child) end
    end
    for _, group in ipairs(manifest.groups) do include(group.tree) end
    for _, relation in pairs(carriedById) do
      local parentId = tonumber(relation.parentInventoryId)
      if not included[parentId] and inputs.inventoryIdToVehId[parentId] then
        restoreState.placedInventoryIds[parentId] = true
      end
    end
    for _, group in ipairs(manifest.groups) do
      local tree = group and group.tree
      if tree then
        local rootIsCurrent = inputs.state.vehicleToEnterId ~= nil and tonumber(tree.inventoryId) == inputs.state.vehicleToEnterId
        inputs.travel.spawnNode(tree, spots, usedSpots, rootIsCurrent, restoreState, carriedById)
      end
    end
    settleRestoreProgress(restoreState)
    local hasCarried = #restoreState.pendingCarried > 0
    if hasCarried then startCarriedRestoreJob(restoreState, spots, usedSpots, carriedById) end
    if inputs.state.vehicleToEnterId and not inputs.inventoryIdToVehId[inputs.state.vehicleToEnterId]
        and (not restoreState.spawnFailedIds[inputs.state.vehicleToEnterId] or inputs.travel.restoreAttempts >= RESTORE_ATTEMPT_LIMIT) then
      inputs.state.vehicleToEnterId = nil
    end

    if inputs.state.loadedVehiclesLocations then
      local function consume(node)
        inputs.state.loadedVehiclesLocations[tonumber(node.inventoryId)] = nil
        for _, child in ipairs(node.children or {}) do consume(child) end
      end
      for _, group in ipairs(manifest.groups) do consume(group.tree) end
    end
    if not hasCarried then settleRestoreProgress(restoreState) end
    return true
  end

  local function manifestInventoryIds(manifest)
    local ids = {}
    local function visit(node)
      if not node then return end
      local inventoryId = tonumber(node.inventoryId)
      if inventoryId then ids[inventoryId] = true end
      for _, child in ipairs(node.children or {}) do visit(child) end
    end
    for _, group in ipairs(manifest and manifest.groups or {}) do visit(group.tree) end
    return ids
  end

  function inputs.travel.isPending(inventoryId)
    return manifestInventoryIds(inputs.travel.pending)[tonumber(inventoryId)] == true
  end

  -- Leaving again must not strand vehicles whose previous arrival is still waiting for a usable spawn.
  function inputs.travel.prepare(manifest)
    local nextManifest = type(manifest) == "table" and deepcopy(manifest) or nil
    if nextManifest and inputs.travel.pending then
      local included = manifestInventoryIds(nextManifest)
      local function retain(node)
        if not node then return end
        local id = tonumber(node.inventoryId)
        if id and not included[id] then
          local tree = deepcopy(node)
          tree.children = {}
          tree.coupledParentInventoryId, tree.couplerOffset = nil, nil
          nextManifest.groups[#nextManifest.groups + 1] = {rootInventoryId = id, tree = tree}
          included[id] = true
        end
        for _, child in ipairs(node.children or {}) do retain(child) end
      end
      for _, group in ipairs(inputs.travel.pending.groups or {}) do retain(group.tree) end
    end
    inputs.travel.savedSession = nil
    inputs.travel.previousArrival = inputs.travel.pending and deepcopy(inputs.travel.pending) or nil
    inputs.travel.activeRestore = nil
    inputs.travel.pending = nextManifest
    inputs.travel.restoreAttempts = 0
  end

  function inputs.travel.clear()
    local previousArrival = inputs.travel.previousArrival
    inputs.travel.activeRestore = nil
    finishPendingRestore()
    inputs.travel.pending = previousArrival
  end

  return {
    bindInputs = function(inputs)
      helpers.removeVehicleObject = inputs.removeVehicleObject
      helpers.spawnVehicle = inputs.spawnVehicle
    end,
  }
end

return travelPart
