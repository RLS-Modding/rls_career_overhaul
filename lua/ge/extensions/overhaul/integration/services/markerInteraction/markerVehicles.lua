-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Interaction collection of Overhaul's marker interaction (integration/services/markerInteraction): the player
-- footprint is the seated vehicle plus coupled or nearby inventory vehicles, each probed against nearby markers
-- so a trailer in a stall still opens the parking prompt. create() returns one collector with its own vehicle
-- boxes and scratch vectors; the marker interaction owns it and passes the frame's shared updateData,
-- interactableElements and prompt (integration/services/markerInteraction/markerPrompt).
local markerVehicles = {}

-- Seated vehicle keeps the normal 100 m nearby query.
-- Extra player vehicles pull markers in a local bubble large enough for a
-- long tanker whose OOB center sits well behind the parking stall.
local SECONDARY_NEAR_RADIUS = 50
local SECONDARY_NEAR_RADIUS_SQ = SECONDARY_NEAR_RADIUS * SECONDARY_NEAR_RADIUS

local function markerOverlaps(marker)
  return marker.overlap ~= false and marker.overlap ~= nil
end
markerVehicles.markerOverlaps = markerOverlaps

local function clusterElemData(marker)
  return marker and marker.cluster and marker.cluster.elemData or nil
end

-- Unbuilt / cleared KD trees have nil tree/nonLeafLimIdx; querying them exceptions every frame.
local function isQueryableClusterQt(clusterQt)
  return clusterQt and clusterQt.tree and clusterQt.nonLeafLimIdx
end
markerVehicles.isQueryableClusterQt = isQueryableClusterQt

-- prompt: the marker interaction's prompt (POI classification and its re-evaluation flags).
function markerVehicles.create(updateData, interactableElements, prompt, promptPolicy)
  local collector = {}
  local getPOIData, isMissionLogisticsPOI = promptPolicy.getPOIData, promptPolicy.isMissionLogisticsPOI

  local p1, p2, p3, p4, p5, p6, p7, p8 = vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
  local bbPoints = {}
  -- The corners of a box; the returned table and vectors are reused by every call.
  local function getBBPoints(bbCenter, bbAxis0, bbAxis1, bbAxis2)
    p1:set(bbCenter) p1:setAdd(bbAxis0) p1:setAdd(bbAxis1) p1:setSub(bbAxis2)
    p2:set(bbCenter) p2:setAdd(bbAxis0) p2:setAdd(bbAxis1) p2:setAdd(bbAxis2)
    p3:set(bbCenter) p3:setSub(bbAxis0) p3:setAdd(bbAxis1) p3:setAdd(bbAxis2)
    p4:set(bbCenter) p4:setSub(bbAxis0) p4:setAdd(bbAxis1) p4:setSub(bbAxis2)
    p5:set(bbCenter) p5:setAdd(bbAxis0) p5:setSub(bbAxis1) p5:setSub(bbAxis2)
    p6:set(bbCenter) p6:setAdd(bbAxis0) p6:setSub(bbAxis1) p6:setAdd(bbAxis2)
    p7:set(bbCenter) p7:setSub(bbAxis0) p7:setSub(bbAxis1) p7:setAdd(bbAxis2)
    p8:set(bbCenter) p8:setSub(bbAxis0) p8:setSub(bbAxis1) p8:setSub(bbAxis2)
    bbPoints[1] = p1; bbPoints[2] = p2; bbPoints[3] = p3; bbPoints[4] = p4;
    bbPoints[5] = p5; bbPoints[6] = p6; bbPoints[7] = p7; bbPoints[8] = p8;
    return bbPoints
  end
  collector.getBBPoints = getBBPoints

  -- Player footprint comes from overhaul_vehicles_playerVehicles: coupler group plus
  -- nearby spawned inventory vehicles so an uncoupled trailer in a stall still
  -- opens the parking prompt.
  local playerVehIds = {}
  local bbPointsScratch = {}
  local playerBBSnap = {
    center = vec3(),
    axis0 = vec3(),
    axis1 = vec3(),
    axis2 = vec3(),
    points = {},
    playerPos = vec3()
  }
  local probePos = vec3()
  local posSnapScratch = vec3()
  local lastSecondaryHitId = nil
  local vehicleBBs = {}
  local bbFrame = 0
  collector.playerVehIds = playerVehIds
  collector.vehicleBBs = vehicleBBs

  -- New frame: vehicle boxes are read again; boxes not used last frame are dropped.
  function collector.beginFrame()
    bbFrame = bbFrame + 1
    for vehId, boundingBox in pairs(vehicleBBs) do
      if boundingBox.frame < bbFrame - 1 then vehicleBBs[vehId] = nil end
    end
  end

  function collector.syncPlayerVehicles(seatedVehId)
    table.clear(playerVehIds)
    if overhaul_vehicles_playerVehicles and overhaul_vehicles_playerVehicles.fillInteractionVehicleIds then
      overhaul_vehicles_playerVehicles.fillInteractionVehicleIds(playerVehIds)
    elseif overhaul_vehicles_playerVehicles and overhaul_vehicles_playerVehicles.fillPlayerVehicleIds then
      overhaul_vehicles_playerVehicles.fillPlayerVehicleIds(playerVehIds)
    elseif seatedVehId then
      playerVehIds[1] = seatedVehId
    end
  end

  function collector.clearPlayerVehicles()
    table.clear(playerVehIds)
  end

  local function copyBBPointsInto(dst, src)
    for i, p in ipairs(src or {}) do
      if dst[i] then
        dst[i]:set(p)
      else
        dst[i] = vec3(p)
      end
    end
    for i = #(src or {}) + 1, #dst do
      dst[i] = nil
    end
    return dst
  end

  local function takePlayerBBSnap()
    if not updateData.bbCenter then return nil end
    playerBBSnap.center:set(updateData.bbCenter)
    playerBBSnap.axis0:set(updateData.bbHalfAxis0)
    playerBBSnap.axis1:set(updateData.bbHalfAxis1)
    playerBBSnap.axis2:set(updateData.bbHalfAxis2)
    copyBBPointsInto(playerBBSnap.points, updateData.bbPoints)
    playerBBSnap.topZ = updateData.highestBBPointZ
    playerBBSnap.playerPos:set(updateData.playerPosition)
    return playerBBSnap
  end
  collector.takePlayerBBSnap = takePlayerBBSnap

  local function getVehicleBB(vehId, includeAxes)
    local boundingBox = vehicleBBs[vehId]
    if not boundingBox then
      boundingBox = {center = vec3(), axis0 = vec3(), axis1 = vec3(), axis2 = vec3(), points = {}}
      vehicleBBs[vehId] = boundingBox
    end
    if boundingBox.frame ~= bbFrame then
      boundingBox.center:set(be:getObjectOOBBCenterXYZ(vehId))
      boundingBox.frame = bbFrame
      boundingBox.axesReady = false
    end
    if includeAxes and not boundingBox.axesReady then
      boundingBox.axis0:set(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
      boundingBox.axis1:set(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
      boundingBox.axis2:set(be:getObjectOOBBHalfAxisXYZ(vehId, 2))
      copyBBPointsInto(boundingBox.points, getBBPoints(boundingBox.center, boundingBox.axis0, boundingBox.axis1, boundingBox.axis2))
      boundingBox.topZ = math.max(boundingBox.points[2].z, math.max(boundingBox.points[3].z, math.max(boundingBox.points[6].z, boundingBox.points[7].z)))
      boundingBox.axesReady = true
    end
    return boundingBox
  end
  collector.getVehicleBB = getVehicleBB

  local function applyVehBB(vehId)
    local boundingBox = getVehicleBB(vehId, true)
    updateData.bbCenter:set(boundingBox.center)
    updateData.bbHalfAxis0:set(boundingBox.axis0)
    updateData.bbHalfAxis1:set(boundingBox.axis1)
    updateData.bbHalfAxis2:set(boundingBox.axis2)
    updateData.bbPoints = copyBBPointsInto(bbPointsScratch, boundingBox.points)
    updateData.highestBBPointZ = boundingBox.topZ
    updateData.playerPosition:set(updateData.bbCenter)
  end
  collector.applyVehBB = applyVehBB

  local function restorePlayerBBSnap(snap)
    if not snap then return end
    updateData.bbCenter:set(snap.center)
    updateData.bbHalfAxis0:set(snap.axis0)
    updateData.bbHalfAxis1:set(snap.axis1)
    updateData.bbHalfAxis2:set(snap.axis2)
    updateData.bbPoints = copyBBPointsInto(bbPointsScratch, snap.points)
    updateData.highestBBPointZ = snap.topZ
    updateData.playerPosition:set(snap.playerPos)
  end
  collector.restorePlayerBBSnap = restorePlayerBBSnap

  -- Probe overlap without ticking marker smoothers (marker:update applies dt each call).
  -- Vanilla checkParking also refuses anything whose *center* is farther than 15 m,
  -- which a long trailer can fail while its bounding box still covers the stall.
  local function probeMarkerOverlap(marker)
    if marker.pos and marker.xVec and marker.yVec and marker.zVec and updateData.bbCenter
        and updateData.bbHalfAxis0 and updateData.bbHalfAxis1 and updateData.bbHalfAxis2 then
      local hit
      if marker.mode == "contained" then
        hit = containsOBB_OBB(marker.pos, marker.xVec, marker.yVec, marker.zVec,
          updateData.bbCenter, updateData.bbHalfAxis0, updateData.bbHalfAxis1, updateData.bbHalfAxis2)
      else
        hit = overlapsOBB_OBB(marker.pos, marker.xVec, marker.yVec, marker.zVec,
          updateData.bbCenter, updateData.bbHalfAxis0, updateData.bbHalfAxis1, updateData.bbHalfAxis2)
      end
      if hit then
        marker.overlap = true
        if marker.parked ~= nil then marker.parked = true end
        return true
      end
      if marker.mode == "contained" or marker.mode == "overlap" then
        marker.overlap = false
        if marker.parked ~= nil then marker.parked = false end
        return false
      end
    end
    if marker.checkParking then
      marker:checkParking(updateData)
      return markerOverlaps(marker)
    end
    -- Non-box marker updates mutate shared state and smoothers.
    return false
  end
  collector.probeMarkerOverlap = probeMarkerOverlap

  local function clusterAllowsSecondaryActivation(marker, vehId)
    if vehId and overhaul_vehicles_playerVehicles and overhaul_vehicles_playerVehicles.isPlayerVehicle
        and overhaul_vehicles_playerVehicles.isPlayerVehicle(vehId) then
      return true
    end
    local elems = clusterElemData(marker)
    if not elems or not elems[1] then return true end
    local sawInspect = false
    for _, elem in ipairs(elems) do
      if isMissionLogisticsPOI(elem) then
        return true
      end
      local data = getPOIData(elem)
      if data and data.type == "logisticsParking" and not data.canInspectCargo then
        return true
      end
      if data and data.canInspectCargo then
        sawInspect = true
      end
    end
    return not sawInspect
  end
  collector.clusterAllowsSecondaryActivation = clusterAllowsSecondaryActivation

  -- Default = stock marker:update with seated BB.
  -- Extra player bodies (coupled or nearby inventory) are probed against every
  -- nearby marker; cheap-reject only skips bodies whose center is far away.
  -- Inspect spots reject unrelated parked vehicles but accept coupled trailers.
  function collector.updateMarkerForPlayerVehicles(marker, clusterPos)
    lastSecondaryHitId = nil
    -- Walking markers track entry/exit per door. Updating them for parked vehicles
    -- can consume the player's entry transition before interaction is collected.
    if marker.doors or #playerVehIds < 2 then
      marker:update(updateData)
      return false, markerOverlaps(marker)
    end

    local markerPos = clusterPos or marker.pos
    local snap
    local hitId = nil

    for i = 2, #playerVehIds do
      local vehId = playerVehIds[i]
      local tooFar = false
      if markerPos then
        probePos:set(getVehicleBB(vehId, false).center)
        local dx = probePos.x - markerPos.x
        local dy = probePos.y - markerPos.y
        local dz = probePos.z - markerPos.z
        tooFar = (dx * dx + dy * dy + dz * dz) > SECONDARY_NEAR_RADIUS_SQ
      end
      if not tooFar then
        snap = snap or takePlayerBBSnap()
        applyVehBB(vehId)
        if probeMarkerOverlap(marker) then
          hitId = vehId
          break
        end
      end
    end

    restorePlayerBBSnap(snap)
    marker:update(updateData)
    local primaryHit = markerOverlaps(marker)
    if hitId and not primaryHit and not clusterAllowsSecondaryActivation(marker, hitId) then
      hitId = nil
    end
    if hitId then
      if marker.parked ~= nil then marker.parked = true end
      if marker.overlap ~= nil then marker.overlap = true end
    end
    lastSecondaryHitId = hitId
    return hitId ~= nil, primaryHit
  end

  function collector.collectMarkerInteractables(marker, secondaryHit, primaryHit, snap, isAtParkingSpeed, isWalking, parkingSpeedChanged)
    if secondaryHit and not primaryHit and not clusterAllowsSecondaryActivation(marker, lastSecondaryHitId) then
      secondaryHit = false
    end
    local canInteract = isAtParkingSpeed and (prompt.isReevaluating() or parkingSpeedChanged)
    if isWalking then
      canInteract = marker.isInAreaChanged or prompt.isReevaluating() or prompt.isWalkingExitCheck() or secondaryHit
    elseif secondaryHit and isAtParkingSpeed then
      canInteract = true
    end

    updateData.canInteract = canInteract
    if not canInteract then return end

    local countBefore = #interactableElements
    marker:interactInPlayMode(updateData, interactableElements)
    if not secondaryHit or #interactableElements > countBefore or not snap or not lastSecondaryHitId then return end
    if not primaryHit and not clusterAllowsSecondaryActivation(marker, lastSecondaryHitId) then return end

    if marker.parked ~= nil then marker.parked = true end
    if marker.overlap ~= nil then marker.overlap = true end

    posSnapScratch:set(updateData.playerPosition)
    applyVehBB(lastSecondaryHitId)
    marker:interactInPlayMode(updateData, interactableElements)
    restorePlayerBBSnap(snap)
    updateData.playerPosition:set(posSnapScratch)
  end

  -- Only secondary player vehicles expand the nearby set, and only in a tight radius.
  function collector.queryClustersNearSecondaryPlayerVehicles(clusterQt, outIds)
    if not isQueryableClusterQt(clusterQt) then
      return
    end
    for i = 2, #playerVehIds do
      probePos:set(getVehicleBB(playerVehIds[i], false).center)
      for id in clusterQt:queryNotNested(
        probePos.x - SECONDARY_NEAR_RADIUS,
        probePos.y - SECONDARY_NEAR_RADIUS,
        probePos.x + SECONDARY_NEAR_RADIUS,
        probePos.y + SECONDARY_NEAR_RADIUS
      ) do
        outIds[id] = true
      end
    end
  end

  return collector
end

return markerVehicles
