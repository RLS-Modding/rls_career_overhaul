-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Vehicle delivery tasks: hauling detection and active task updates.
-- Read config, hauler groups, coupled trains, support geometry, cargo acquisition, task phases and binding.

-- Part of the Overhaul fork of stock lua/ge/extensions/career/modules/delivery/vehicleTasks.lua.

local part = {}
local vehicleCommands = require("overhaul/lib/vehicles/vehicleCommands")

-- Config ------------------------------------------------------------------------------------------

local bringToDestinationThreshold = 20 * 20

local HAUL_DWELL_S = 2.5
local HAUL_LOST_S = 3.0
local HAUL_REL_SPEED_SQ = 2.5 * 2.5
local HAUL_WALKER_NEAR_SQ = 50 * 50
local HAUL_BOUNDS_MARGIN_M = 1 -- slack added to the summed half-extents when pruning by bounds
local HAUL_SUPPORT_FRACTION = 0.75 -- share of cargo wheels that must rest on the carrier
local HAUL_MIN_SURFACE_NORMAL_Z = 0.35 -- a triangle steeper than this (|nz| / |normal|) cannot carry a wheel
local HAUL_DEGENERATE_NORMAL = 1e-8
local HAUL_CONTACT_HEIGHT_M = 0.12 -- tread points this close to the wheel's lowest point can touch
local HAUL_BARYCENTRIC_TOLERANCE = 0.00001
local HAUL_BARYCENTRIC_SUM_MAX = 1.00001
local HAUL_GAP_MIN_M, HAUL_GAP_MAX_M = -0.08, 0.065 -- allowed wheel-to-surface gap; negative means sunk in

-- Hauling and task updates -------------------------------------------------------------------------

function part.new(inputs)
  local api = {}
  local deliveryServices, taskState = assert(inputs.services), assert(inputs.state)
  local callbacks = {}

  local haulGroupScratch = {}
  local coupledGroupScratch = {}

  local haulSupport = {time = 0, topology = {}, pairs = {}, requestId = 0}

  local function isUnicycleVehId(vehId)
    if not vehId or vehId < 0 then return true end
    local obj = getObjectByID(vehId)
    return not obj or (obj.getJBeamFilename and obj:getJBeamFilename() == "unicycle")
  end

  function api.isActiveCargoTaskVehId(vehId)
    if not vehId then return false end
    for _, taskData in ipairs(taskState.vehicleTasks) do
      if not taskData.remove and taskData.vehId == vehId then
        return true
      end
    end
    return false
  end

  function api.fillHaulerGroup(haulerRootId)
    overhaul_vehicles_playerVehicles.fillCouplerGroup(haulerRootId, haulGroupScratch, { resolveLead = true })
  end

  function api.memberCanBedCarry(obj)
    if not obj or isUnicycleVehId(obj:getID()) then return false end
    local data = core_vehicle_manager.getVehicleData(obj:getID())
    return data and data.vdata and next(data.vdata.triangles or {}) ~= nil or false
  end

  local function haulerTrainCanHaulCargo(haulerRootId)
    if not haulerRootId then return false end
    api.fillHaulerGroup(haulerRootId)
    for _, id in ipairs(haulGroupScratch) do
      local obj = getObjectByID(id)
      if api.memberCanBedCarry(obj) then
        return true
      end
    end
    return false
  end

  local function reassertEmploymentJockeyRoute()
    if not callbacks.isEmploymentJockeyShift() then return end
    callbacks.navigateToActiveTasks()
    local emp = overhaul_career_work_employment
    if emp and emp.onVehicleTaskStepChanged then
      emp.onVehicleTaskStepChanged()
    elseif deliveryServices.general and deliveryServices.general.requestDeliveryPoiRefresh then
      deliveryServices.general.requestDeliveryPoiRefresh(true)
    end
  end

  function api.onVehicleSwitched(oldId, newId)
    if newId and newId >= 0 and not isUnicycleVehId(newId) and not api.isActiveCargoTaskVehId(newId) then
      if haulerTrainCanHaulCargo(newId) then
        taskState.lastHaulerVehId = newId
      end
    end
    if not callbacks.isEmploymentJockeyShift() then return end
    core_jobsystem.create(function(job)
      job.sleep(0)
      reassertEmploymentJockeyRoute()
    end)
  end

  -- Coupled train and destination checks -------------------------------------------------------------

  -- A delivery trailer may be several coupler hops behind the controlled cab. Direct-parent equality makes a rear B-train trailer look uncoupled unless the player switches control into the lead trailer.
  local function isTrailerInPlayerTrain(vehId)
    local playerVehId = be:getPlayerVehicleID(0)
    if not playerVehId or playerVehId == -1 then return false end

    overhaul_vehicles_playerVehicles.fillCouplerGroup(vehId, coupledGroupScratch, { resolveLead = true })
    local containsPlayer = false
    local groupCount = 0
    for _, groupVehId in ipairs(coupledGroupScratch) do
      groupCount = groupCount + 1
      if groupVehId == playerVehId then
        containsPlayer = true
      end
    end
    if not containsPlayer then return false end
    -- Sitting in a detached delivery trailer still puts vehId in the group. Require another attached vehicle before treating that as coupled.
    if playerVehId == vehId then
      return groupCount > 1
    end
    return true
  end

  -- Coupler-group proximity via overhaul_vehicles_playerVehicles (footprint only; job trailers stay loaners).
  local function isGroupNearDestination(vehId, destinationPos, thresholdSq)
    if not destinationPos then return false end
    overhaul_vehicles_playerVehicles.fillCouplerGroup(vehId, coupledGroupScratch, { resolveLead = true })
    for _, id in ipairs(coupledGroupScratch) do
      local obj = scenetree.findObjectById(id)
      local pos = obj and obj:getPosition()
      if pos then
        local dx, dy, dz = pos.x - destinationPos.x, pos.y - destinationPos.y, pos.z - destinationPos.z
        if dx * dx + dy * dy + dz * dz <= thresholdSq then return true end
      end
    end
    return false
  end

  function haulSupport.invalidate(id)
    if taskState.lastHaulerVehId == id then taskState.lastHaulerVehId = nil end
    haulSupport.topology[id] = nil
    for key, state in pairs(haulSupport.pairs) do
      if state.cargoId == id or state.rootId == id or (state.members and state.members[id]) then
        haulSupport.pairs[key] = nil
      end
    end
    for _, task in ipairs(taskState.vehicleTasks) do
      if task.vehId == id or task.haulerVehId == id then
        task.haulAcquired, task.haulerVehId = nil, nil
      end
    end
  end

  function haulSupport.getTopology(obj)
    local id = obj:getID()
    local data = core_vehicle_manager.getVehicleData(id)
    if not data or not data.vdata then return nil end
    local cached = haulSupport.topology[id]
    if cached and cached.source == data.vdata then return cached end
    if cached then haulSupport.invalidate(id) end
    cached = {source = data.vdata, triangles = {}, nodeIds = {}, wheels = {}}
    local nodes = {}
    for key, t in pairs(data.vdata.triangles or {}) do
      if t.triangleType ~= 2 and t.triangleType ~= 'NONCOLLIDABLE' and t.id1 and t.id2 and t.id3 then
        cached.triangles[#cached.triangles + 1] = {t.id1, t.id2, t.id3, id = key}
        nodes[t.id1], nodes[t.id2], nodes[t.id3] = true, true, true
      end
    end
    for node in pairs(nodes) do cached.nodeIds[#cached.nodeIds + 1] = node end
    for _, wheel in pairs(data.vdata.wheels or {}) do
      cached.wheels[#cached.wheels + 1] = wheel.treadNodes or wheel.nodes or {}
    end
    haulSupport.topology[id] = cached
    return cached
  end

  function haulSupport.surfaceNodes(obj, cached, allowPendingDamage)
    local now = haulSupport.time
    if not cached.requestTime or now - cached.requestTime >= 1 then
      haulSupport.requestId = haulSupport.requestId + 1
      cached.requestId, cached.requestTime = haulSupport.requestId, now
      obj:queueLuaCommand("extensions.load('overhaulCollisionEnvelope'); extensions."
        .. vehicleCommands.call("overhaulCollisionEnvelope", "requestHaulSurfaceDamage", cached.requestId))
    end
    if not allowPendingDamage and (not cached.damageTime or now - cached.damageTime > 2) then return nil end
    if cached.nodeTime ~= now then
      local pos = obj:getPosition()
      cached.nodes = {}
      for _, id in ipairs(cached.nodeIds) do cached.nodes[id] = pos + obj:getNodePosition(id) end
      cached.nodeTime = now
    end
    return cached.nodes
  end

  -- Bed support geometry -----------------------------------------------------------------------------

  -- Cargo and carrier bounds only prune candidates; wheel-to-surface support decides loading.
  local function boundsMayTouch(cargoId, carrierId)
    if not (be:getObjectOOBBIsInitialized(cargoId) and be:getObjectOOBBIsInitialized(carrierId)) then return true end
    local radius = HAUL_BOUNDS_MARGIN_M
    for axis = 0, 2 do
      radius = radius + vec3(be:getObjectOOBBHalfAxisXYZ(cargoId, axis)):length()
        + vec3(be:getObjectOOBBHalfAxisXYZ(carrierId, axis)):length()
    end
    local apart = vec3(be:getObjectOOBBCenterXYZ(cargoId)) - vec3(be:getObjectOOBBCenterXYZ(carrierId))
    return apart:squaredLength() <= radius * radius
  end

  -- World-space tread points of each cargo wheel with their horizontal extent and lowest height.
  local function collectWheelContacts(cargoObj, cargoTopology)
    local wheels, pos = {}, cargoObj:getPosition()
    for _, ids in ipairs(cargoTopology.wheels) do
      local wheelContacts = {points = {}, minx = math.huge, miny = math.huge, minz = math.huge, maxx = -math.huge, maxy = -math.huge}
      for _, id in ipairs(ids) do
        local p = pos + cargoObj:getNodePosition(id)
        wheelContacts.points[#wheelContacts.points + 1] = p
        wheelContacts.minx, wheelContacts.maxx = math.min(wheelContacts.minx, p.x), math.max(wheelContacts.maxx, p.x)
        wheelContacts.miny, wheelContacts.maxy = math.min(wheelContacts.miny, p.y), math.max(wheelContacts.maxy, p.y)
        wheelContacts.minz = math.min(wheelContacts.minz, p.z)
      end
      wheels[#wheels + 1] = wheelContacts
    end
    return wheels
  end

  -- Fills `tri` with the geometry of carrier triangle a-b-c. False when it cannot carry a wheel (degenerate, or steeper than HAUL_MIN_SURFACE_NORMAL_Z).
  local function fillSupportTriangle(tri, a, b, c)
    local ux, uy, uz = b.x-a.x, b.y-a.y, b.z-a.z
    local vx, vy, vz = c.x-a.x, c.y-a.y, c.z-a.z
    local nx, ny, nz = uy*vz-uz*vy, uz*vx-ux*vz, ux*vy-uy*vx
    local norm = math.sqrt(nx*nx + ny*ny + nz*nz)
    if norm <= HAUL_DEGENERATE_NORMAL or math.abs(nz)/norm < HAUL_MIN_SURFACE_NORMAL_Z then return false end
    tri.a = a
    tri.ux, tri.uy, tri.uz, tri.vx, tri.vy, tri.vz = ux, uy, uz, vx, vy, vz
    tri.nz, tri.norm = nz, norm
    tri.minx, tri.maxx = math.min(a.x,b.x,c.x), math.max(a.x,b.x,c.x)
    tri.miny, tri.maxy = math.min(a.y,b.y,c.y), math.max(a.y,b.y,c.y)
    return true
  end

  -- True when tread point p lies over the triangle and within the allowed gap above it.
  local function treadPointRestsOnTriangle(p, wheelMinZ, tri)
    if p.z > wheelMinZ + HAUL_CONTACT_HEIGHT_M then return false end
    if p.x < tri.minx or p.x > tri.maxx or p.y < tri.miny or p.y > tri.maxy then return false end
    local a, nz = tri.a, tri.nz
    local px, py = p.x-a.x, p.y-a.y
    local u, v = (px*tri.vy-py*tri.vx)/nz, (tri.ux*py-tri.uy*px)/nz
    if u < -HAUL_BARYCENTRIC_TOLERANCE or v < -HAUL_BARYCENTRIC_TOLERANCE or u+v > HAUL_BARYCENTRIC_SUM_MAX then return false end
    local gap = (p.z-a.z-u*tri.uz-v*tri.vz)*math.abs(nz)/tri.norm
    return gap >= HAUL_GAP_MIN_M and gap <= HAUL_GAP_MAX_M
  end

  local function wheelRestsOnTriangle(wheelContacts, tri)
    if not (tri.maxx >= wheelContacts.minx and tri.minx <= wheelContacts.maxx and tri.maxy >= wheelContacts.miny and tri.miny <= wheelContacts.maxy) then return false end
    for _, p in ipairs(wheelContacts.points) do
      if treadPointRestsOnTriangle(p, wheelContacts.minz, tri) then return true end
    end
    return false
  end

  local supportTriangleScratch = {}

  -- Cargo support and proximity ----------------------------------------------------------------------

  function api.cargoOnMemberBed(cargoObj, haulerObj, allowPendingDamage)
    if not cargoObj or not haulerObj or cargoObj:getID() == haulerObj:getID() then return false end
    if (cargoObj:getVelocity() - haulerObj:getVelocity()):squaredLength() > HAUL_REL_SPEED_SQ then return false end
    if not boundsMayTouch(cargoObj:getID(), haulerObj:getID()) then return false end
    local cargo, carrier = haulSupport.getTopology(cargoObj), haulSupport.getTopology(haulerObj)
    if not cargo or not carrier or #cargo.wheels < 2 then return false end
    local nodes = haulSupport.surfaceNodes(haulerObj, carrier, allowPendingDamage)
    if not nodes then return false, true end

    local wheels = collectWheelContacts(cargoObj, cargo)
    local supported, required = 0, math.ceil(#wheels * HAUL_SUPPORT_FRACTION)
    local tri = supportTriangleScratch
    for _, t in ipairs(carrier.triangles) do
      local broken = carrier.broken and carrier.broken[t.id]
      if not broken and fillSupportTriangle(tri, nodes[t[1]], nodes[t[2]], nodes[t[3]]) then
        for _, wheelContacts in ipairs(wheels) do
          if not wheelContacts.supported and wheelRestsOnTriangle(wheelContacts, tri) then
            wheelContacts.supported, supported = true, supported + 1
            if supported >= required then return true end
          end
        end
      end
    end
    return false
  end

  local function cargoNearHaulerBed(cargoObj, haulerRootId)
    if not cargoObj or not haulerRootId then return false end
    api.fillHaulerGroup(haulerRootId)
    local cargoId = cargoObj:getID()
    for _, id in ipairs(haulGroupScratch) do
      if id ~= cargoId and not api.isActiveCargoTaskVehId(id) then
        local hauler = getObjectByID(id)
        if api.memberCanBedCarry(hauler) and api.cargoOnMemberBed(cargoObj, hauler) then
          return true
        end
      end
    end
    return false
  end

  function haulSupport.isLoaded(cargoId, rootId)
    if not cargoId or not rootId or cargoId == rootId then return false end
    local cargo, root = getObjectByID(cargoId), getObjectByID(rootId)
    if not cargo or not root then return false end
    local key, now = tostring(cargoId) .. ':' .. tostring(rootId), haulSupport.time
    local state = haulSupport.pairs[key]
    if not state or now - state.used > 2 then
      state = {cargoId = cargoId, rootId = rootId, loaded = false}
      haulSupport.pairs[key] = state
    end
    state.used = now
    if state.sampleTime and now - state.sampleTime < 0.25 then return state.loaded, state.supportSince ~= nil end
    local supported = cargoNearHaulerBed(cargo, rootId)
    if haulSupport.pairs[key] ~= state then
      state = {cargoId = cargoId, rootId = rootId, loaded = false, used = now}
    end
    state.members = {}
    for _, id in ipairs(haulGroupScratch) do state.members[id] = true end
    haulSupport.pairs[key] = state
    state.sampleTime = now
    if supported then
      state.lostSince = nil
      state.supportSince = state.supportSince or now
      if now - state.supportSince >= HAUL_DWELL_S then state.loaded = true end
    else
      state.supportSince = nil
      state.lostSince = state.lostSince or now
      if now - state.lostSince >= HAUL_LOST_S then state.loaded = false end
    end
    return state.loaded, state.supportSince ~= nil
  end

  -- Hauler selection and acquisition -----------------------------------------------------------------

  local function pickHaulerForCargo(cargoVehId, cargoPos)
    local playerId = be:getPlayerVehicleID(0)
    if playerId and playerId >= 0 and playerId ~= cargoVehId and not isUnicycleVehId(playerId)
        and not api.isActiveCargoTaskVehId(playerId) and haulerTrainCanHaulCargo(playerId) then
      return playerId
    end

    local walkerPos = nil
    if playerId and playerId >= 0 then
      local walker = getObjectByID(playerId)
      walkerPos = walker and walker:getPosition() or nil
    end
    if not walkerPos then
      walkerPos = core_camera.getPosition()
    end

    local function walkerNear(pos)
      if not walkerPos or not pos then return true end
      return (walkerPos - pos):squaredLength() <= HAUL_WALKER_NEAR_SQ
    end

    if taskState.lastHaulerVehId and taskState.lastHaulerVehId ~= cargoVehId and not isUnicycleVehId(taskState.lastHaulerVehId)
        and not api.isActiveCargoTaskVehId(taskState.lastHaulerVehId) and haulerTrainCanHaulCargo(taskState.lastHaulerVehId) then
      local last = getObjectByID(taskState.lastHaulerVehId)
      if last then
        local lastPos = last:getPosition()
        if walkerNear(lastPos) or (cargoPos and (lastPos - cargoPos):squaredLength() <= HAUL_WALKER_NEAR_SQ) then
          return taskState.lastHaulerVehId
        end
      end
    end

    local inv = overhaul_career_garage_inventory
    local map = inv and inv.getMapInventoryIdToVehId and inv.getMapInventoryIdToVehId()
    if not map or not cargoPos then return nil end
    local bestId = nil
    local bestDist = nil
    for _, vehId in pairs(map) do
      if vehId and vehId ~= cargoVehId and not isUnicycleVehId(vehId)
          and not api.isActiveCargoTaskVehId(vehId) and haulerTrainCanHaulCargo(vehId) then
        local obj = getObjectByID(vehId)
        if obj then
          local pos = obj:getPosition()
          local distSq = (pos - cargoPos):squaredLength()
          if distSq <= HAUL_WALKER_NEAR_SQ and walkerNear(pos) and (not bestDist or distSq < bestDist) then
            bestId, bestDist = vehId, distSq
          end
        end
      end
    end
    return bestId
  end

  -- Cargo on a bed/in a dryvan is not coupler-linked; when acquired (or still on the hauler), destination proximity follows the truck/trailer train instead.
  local function isCargoNearDestination(taskData, destinationPos, thresholdSq)
    if not taskData or not taskData.vehId then return false end
    local groupNear = isGroupNearDestination(taskData.vehId, destinationPos, thresholdSq)
    -- Trailer arrival follows the coupled train; sampling the truck's bed cannot
    -- add an arrival path and rebuilds its surface while the train is driving.
    local offer = taskData.offer
    local offerType = offer and offer.data and offer.data.type
    if offerType == "trailer" or (not offerType and offer and offer.task
        and offer.task.type == "trailerDropOff") then return groupNear end
    if groupNear then return true end
    local haulerId = taskData.haulerVehId
    return haulerId and haulSupport.isLoaded(taskData.vehId, haulerId)
      and isGroupNearDestination(haulerId, destinationPos, thresholdSq) or false
  end

  local function tryHaulAcquireOnCapableHauler(taskData, dtSim)
    local cargo = getObjectByID(taskData.vehId)
    if not cargo then
      taskData.haulAcquired, taskData.haulerVehId = nil, nil
      return false
    end
    local candidates, seen = {}, {}
    local function add(id)
      if id and not seen[id] and id ~= taskData.vehId and not isUnicycleVehId(id)
          and not api.isActiveCargoTaskVehId(id) then
        candidates[#candidates + 1], seen[id] = id, true
      end
    end
    add(taskData.haulerVehId)
    add(pickHaulerForCargo(taskData.vehId, cargo:getPosition()))
    add(taskState.lastHaulerVehId)
    local inv = overhaul_career_garage_inventory
    for _, id in pairs(inv and inv.getMapInventoryIdToVehId and inv.getMapInventoryIdToVehId() or {}) do add(id) end
    local pending = false
    for _, id in ipairs(candidates) do
      local loaded, acquiring = haulSupport.isLoaded(taskData.vehId, id)
      if loaded then
        taskData.haulAcquired, taskData.haulerVehId = true, id
        taskState.lastHaulerVehId = id
        return true
      end
      pending = pending or acquiring
    end
    taskData.haulAcquired, taskData.haulerVehId = nil, nil
    return false, pending
  end

  -- Active task phases ----------------------------------------------------------------------------

  local function installTaskPhases()
    -- Moves the active task pointer and tells the task list which row changed.
    local function moveActiveTask(taskData, step)
      taskData.activeTaskIndex = taskData.activeTaskIndex + step
      deliveryServices.tasklist.updateTasklistForOfferId(taskData.offer.id)
    end

    -- Phases. Each checks its own task type, in the order below, against the task captured at the start.

    -- Any controlled member of the same connected train counts, including a cab towing a multi-trailer combination.
    local function coupleTrailerPhase(taskData, activeTask)
      if activeTask.type ~= "coupleTrailer" then return end
      if isTrailerInPlayerTrain(taskData.vehId) then
        taskData.haulerVehId = be:getPlayerVehicleID(0)
        moveActiveTask(taskData, 1)
      end
    end

    local function enterVehiclePhase(taskData, activeTask, dtSim)
      if activeTask.type ~= "enterVehicle" then return end
      if be:getPlayerVehicleID(0) == taskData.vehId then
        moveActiveTask(taskData, 1)
      elseif tryHaulAcquireOnCapableHauler(taskData, dtSim) then
        moveActiveTask(taskData, 1)
      end
    end

    -- True when the trailer still rides with the player's train or with its hauler.
    local function trailerStillCoupled(taskData)
      local trailerCoupled = isTrailerInPlayerTrain(taskData.vehId)
      if not trailerCoupled and taskData.haulerVehId and overhaul_vehicles_playerVehicles then
        overhaul_vehicles_playerVehicles.fillCouplerGroup(taskData.vehId, coupledGroupScratch, { resolveLead = true })
        for _, id in ipairs(coupledGroupScratch) do
          if id == taskData.haulerVehId and id ~= taskData.vehId then trailerCoupled = true; break end
        end
      end
      if not trailerCoupled and isUnicycleVehId(be:getPlayerVehicleID(0)) then
        local lead = core_trailerRespawn.getAttachedNonTrailer(taskData.vehId)
        trailerCoupled = lead and lead ~= taskData.vehId or false
      end
      return trailerCoupled
    end

    -- Uncoupled with no hauler to go back to: step back to the previous task. Returns true when it did, which ends this task's update for the frame.
    local function uncoupledBeforeArrival(taskData, activeTask, dtSim)
      local trailerCoupled = trailerStillCoupled(taskData)
      local loaded = nil
      local acquiring = nil
      if not trailerCoupled then loaded, acquiring = tryHaulAcquireOnCapableHauler(taskData, dtSim) end
      if trailerCoupled or loaded or acquiring then return false end
      activeTask.uncoupled = nil
      moveActiveTask(taskData, -1)
      taskState.taskThatChangedThisFrame = taskData
      return true
    end

    local function exitVehicleBackOn(taskData, activeTask, dtSim)
      if activeTask.backOn == "exitVehicle" and be:getPlayerVehicleID(0) ~= taskData.vehId then
        local _, acquiring = tryHaulAcquireOnCapableHauler(taskData, dtSim)
        if not taskData.haulAcquired and not acquiring then
          moveActiveTask(taskData, -1)
        end
      end
    end

    -- Returns true when the task stepped back after uncoupling, which stops the update here.
    local function bringToDestinationPhase(taskData, activeTask, dtSim)
      if activeTask.type ~= "bringToDestination" then return false end
      if not activeTask.destination or not activeTask.destination.psPath then
        activeTask.destination = callbacks.resolveVehicleDestination(taskData, activeTask.destination)
      end
      if activeTask.backOn and activeTask.backOn:lower() == "uncouple" and uncoupledBeforeArrival(taskData, activeTask, dtSim) then
        return true
      end
      exitVehicleBackOn(taskData, activeTask, dtSim)
      -- Coupler train near spot, or bed/enclosed cargo whose hauler train is near.
      local destinationPos = deliveryServices.generator.getLocationCoordinates(activeTask.destination)
      if isCargoNearDestination(taskData, destinationPos, bringToDestinationThreshold) then
        moveActiveTask(taskData, 1)
      end
      return false
    end

    local function putIntoParkingSpotPhase(taskData, activeTask)
      if activeTask.type ~= "putIntoParkingSpot" then return end
      -- check if parked in spot and uncoupled
      local destinationPs = deliveryServices.generator.getParkingSpotByPath(activeTask.destination.psPath)
      local valid = destinationPs:checkParking(taskData.vehId)
      simpleDebugText3d(valid and "Valid" or "Invalid", destinationPs.pos + vec3(0,0,2), 0.25, valid and ColorF(0,1,0,0.25) or ColorF(1,0,0,0.25))
      destinationPs:drawDebug()
      if valid then
        if activeTask.forwardOn == "unCouple" and not isTrailerInPlayerTrain(taskData.vehId) then
          moveActiveTask(taskData, 1)
        end
        if activeTask.forwardOn == "exitVehicle" and be:getPlayerVehicleID(0) ~= taskData.vehId then
          moveActiveTask(taskData, 1)
        end
      end

      -- Too far: only roll back when the whole train has left the area, not a rear trailer.
      local destinationPos = deliveryServices.generator.getLocationCoordinates(activeTask.destination)
      if not isCargoNearDestination(taskData, destinationPos, bringToDestinationThreshold * 1.5) then
        moveActiveTask(taskData, -1)
      end
    end

    local function confirmDropOffPhase(taskData, activeTask)
      if activeTask.type ~= "confirmDropOff" then return end
      if not activeTask.destination or not activeTask.destination.psPath then
        activeTask.destination = callbacks.resolveVehicleDestination(taskData, activeTask.destination)
      end
    end

    function api.processActiveTask(taskData, dtSim)
      if taskData.logisticsPending then return end
      local taskIndexBefore = taskData.activeTaskIndex
      local activeTask = taskData.tasks[taskData.activeTaskIndex]
      coupleTrailerPhase(taskData, activeTask)
      enterVehiclePhase(taskData, activeTask, dtSim)
      if bringToDestinationPhase(taskData, activeTask, dtSim) then return end
      putIntoParkingSpotPhase(taskData, activeTask)
      confirmDropOffPhase(taskData, activeTask)

      if taskIndexBefore ~= taskData.activeTaskIndex then
        taskState.taskThatChangedThisFrame = taskData
      end
    end

    -- Trailer events --------------------------------------------------------------------------------

    function api.onTrailerAttached(objId1, objId2)
      for _, taskData in ipairs(taskState.vehicleTasks) do
        if taskData.vehId then
          taskData.loanerOrganisations = taskData.loanerOrganisations or {}
          tableMerge(taskData.loanerOrganisations, overhaul_career_logistics_loanerVehicles.getLoaningOrgsOfVehicle(taskData.vehId))
        end
      end
    end
  end
  installTaskPhases()

  -- Binding and shared scratch buffers ---------------------------------------------------------------

  function api.bindInputs(bindings)
      callbacks.isEmploymentJockeyShift = assert(type(bindings.isEmploymentJockeyShift) == 'function' and bindings.isEmploymentJockeyShift, 'hauling.isEmploymentJockeyShift callback required')
      callbacks.navigateToActiveTasks = assert(type(bindings.navigateToActiveTasks) == 'function' and bindings.navigateToActiveTasks, 'hauling.navigateToActiveTasks callback required')
      callbacks.resolveVehicleDestination = assert(type(bindings.resolveVehicleDestination) == 'function' and bindings.resolveVehicleDestination, 'hauling.resolveVehicleDestination callback required')
  end

  api.haulGroupScratch = haulGroupScratch
  api.haulSupport = haulSupport
  return api
end

return part
