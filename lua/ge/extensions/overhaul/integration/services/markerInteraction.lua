-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/gameplay/markerInteraction.lua (BeamNG 0.40).

-- Updates nearby service markers, interaction prompts and navigation guidance.
local M = {}

local function isOverhaulActive()
  return overhaul_shell_gameMode and overhaul_shell_gameMode.isActive() == true
end
M.dependencies = {'overhaul_integration_services_missions_missionManager','freeroam_bigMapMode', 'gameplay_playmodeMarkers', 'freeroam_bigMapPoiProvider','ui_missionInfo'}

local lastPosition = vec3(0,0,0)
local lastSpeedMetersPerSecond
local tmpVec = vec3()
local markersVisibleTemporary = true

local positionDelta = vec3()
local function getVelocity(dtSim, position)
  if not position then return 0 end
  lastSpeedMetersPerSecond = lastSpeedMetersPerSecond or 10

  if dtSim > 0 then
    positionDelta:setSub2(position, lastPosition)
    lastSpeedMetersPerSecond = positionDelta:length() / dtSim
  end
  lastPosition:set(position)
  return lastSpeedMetersPerSecond
end

local function inverseLerp(min, max, value)
 if math.abs(max - min) < 1e-30 then return min end
 return (value - min) / (max - min)
end


local atParkingSpeed, atParkingSpeedPrev
local minParkingSpeedMetersPerSecond, maxParkingSpeedMetersPerSecond = 1/3.6, 3/3.6
local function getParkingSpeedFactor(playerVelocity)
  if playerVelocity < minParkingSpeedMetersPerSecond then atParkingSpeed =  true end
  if playerVelocity > maxParkingSpeedMetersPerSecond then atParkingSpeed = false end
  if atParkingSpeed == nil    then atParkingSpeed = playerVelocity < minParkingSpeedMetersPerSecond end
  local atParkingSpeedChanged = atParkingSpeed ~= atParkingSpeedPrev
  atParkingSpeedPrev = atParkingSpeed
  return clamp(inverseLerp(minParkingSpeedMetersPerSecond*1.25, minParkingSpeedMetersPerSecond*0.75, playerVelocity),0,1), atParkingSpeed, atParkingSpeedChanged
end

local atCruisingSpeed, atCruisingSpeedPrev
local minCruisingSpeedMetersPerSecond, maxCruisingSpeedMetersPerSecond = 20/3.6, 30/3.6
local function getCruisingSpeedFactor(playerVelocity)
  if playerVelocity < minCruisingSpeedMetersPerSecond then atCruisingSpeed =  false end
  if playerVelocity > maxCruisingSpeedMetersPerSecond then atCruisingSpeed = true end
  if atCruisingSpeed == nil    then atCruisingSpeed = playerVelocity > minCruisingSpeedMetersPerSecond end
  local atCruisingSpeedChanged = atCruisingSpeed ~= atCruisingSpeedPrev
  atCruisingSpeedPrev = atCruisingSpeed
  return (atCruisingSpeed and 1 or 0), atCruisingSpeed, atCruisingSpeedChanged
end


-- Prompt policy (integration/services/markerInteraction/markerPrompt) and interaction collection (integration/services/markerInteraction/markerVehicles) are this extension's
-- own instances, created with it.
local promptPolicy = require('overhaul/integration/services/markerInteraction/markerPrompt')
local prompt = promptPolicy.create(isOverhaulActive)

M.getCurrentInteractableElements = prompt.getCurrentInteractableElements

-- Missions are not part of Overhaul: no mission details to format. Kept as an empty
-- compatibility result while a stock caller can still ask for the mission panel data.
M.formatDataForUi = function() return {} end


local function getGameContext(fromMissionMenu)
  return {context = 'empty'}
end
M.getGameContext = getGameContext


local closeViewDetailPrompt = prompt.closePrompt
local dismissViewDetailPrompt = prompt.dismissViewDetailPrompt
M.dismissViewDetailPrompt = dismissViewDetailPrompt
M.isActivityPromptOpen = prompt.isActivityPromptOpen
M.onMissionInfoChangedState = prompt.onMissionInfoChangedState
M.onInputBindingsChanged = prompt.refreshInputConflicts
M.onVehicleSwitched = prompt.refreshInputConflicts
M.onVehicleSpawned = prompt.refreshInputConflicts
M.onVehicleReplaced = prompt.refreshInputConflicts

-- Clusters are rebuilt, never edited, when their POIs change; remember the answer per cluster table.
local serviceClusters = setmetatable({}, {__mode = 'k'})
local function isServiceCluster(cluster)
  local service = serviceClusters[cluster]
  if service == nil then
    service = promptPolicy.classifyCluster(cluster)
    serviceClusters[cluster] = service
  end
  return service
end

local screenWidth, screenHeight, screenRatio = 1,1,1
local function onSettingsChanged()
  if not isOverhaulActive() then return end
  local vm = GFXDevice.getVideoMode()
  screenWidth = vm.width
  screenHeight = vm.height
  screenRatio = screenWidth / screenHeight
end
M.onSettingsChanged = onSettingsChanged

local veh

local updateData = {}
local decals = {}
local nearbyIds = {}
local previousNearbyIds = {}
local quadTreeSettings = {}
local clustersById = {}
local interactableElements = {}
local markerVehiclesLib = require('overhaul/integration/services/markerInteraction/markerVehicles')
local vehicles = markerVehiclesLib.create(updateData, interactableElements, prompt, promptPolicy)

local lastCamPos = vec3()
local lastCamVel = vec3()
local playerVelLast = vec3()
local timeSincePlayerTeleport

local markerVisibilityBySetting = {}

local multiseatUpdateDataByPlayer = {}
local multiseatPlayerData = {}
local multiseatPlayers = {}
local multiseatActiveMarkers = {}
local multiseatMarkerGeneration = -1
local multiseatInteractionActive = false

local function displayMultiseatTriggers(dtReal)
  local markerGeneration = gameplay_rawPois.getRawPoiGeneration()
  if multiseatMarkerGeneration ~= markerGeneration then
    table.clear(multiseatActiveMarkers)
    multiseatMarkerGeneration = markerGeneration
  end
  table.clear(multiseatPlayerData)
  local clusterQt = gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree()
  local maxRadius = 100

  core_multiseat.getPlayers(multiseatPlayers)
  for _, playerIndex in ipairs(multiseatPlayers) do
    local playerVehicle = getPlayerVehicle(playerIndex)
    if playerVehicle then
      local data = multiseatUpdateDataByPlayer[playerIndex]
      if not data then
        data = {
          vehPos = vec3(),
          vehPos2d = vec3(),
          vehVelocity = vec3(),
          nearbyIds = {},
        }
        multiseatUpdateDataByPlayer[playerIndex] = data
      end

      data.playerIndex = playerIndex
      data.veh = playerVehicle
      data.vehPos:set(playerVehicle:getPositionXYZ())
      data.vehPos2d:set(data.vehPos)
      data.vehPos2d.z = 0
      data.vehVelocity:set(playerVehicle:getVelocityXYZ())
      data.isWalking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking(playerIndex) or false
      data.dt = dtReal
      table.clear(data.nearbyIds)

      for id in clusterQt:queryNotNested(
        data.vehPos.x - maxRadius,
        data.vehPos.y - maxRadius,
        data.vehPos.x + maxRadius,
        data.vehPos.y + maxRadius
      ) do
        data.nearbyIds[id] = true
      end
      table.insert(multiseatPlayerData, data)
    end
  end

  for _, cluster in ipairs(gameplay_playmodeMarkers.getPlaymodeClusters()) do
    local marker = multiseatActiveMarkers[cluster.id]
    local isNearby = false
    for _, data in ipairs(multiseatPlayerData) do
      if isServiceCluster(cluster) and data.nearbyIds[cluster.id] then
        marker = marker or gameplay_playmodeMarkers.getMarkerForCluster(cluster)
        multiseatActiveMarkers[cluster.id] = marker
        if marker.interactWhileMoving then
          marker:interactWhileMoving(data)
        end
        isNearby = true
      end
    end
    if not isNearby and marker then
      marker:hide()
      multiseatActiveMarkers[cluster.id] = nil
    end
  end
end

-- Markers outside the nearby/focus branch are hidden and hide() is idempotent, so after a full walk per cluster
-- generation only nearby, focused and last frame's branch markers need a visit. Visits keep the cluster order.
local markerWalkClusters
local markerWalkFull = true
local markerWalkMarkers = {}
local markerWalkIndicesById = {}
local markerWalkFocus = {}
local markerWalkVisit = {}
local markerWalkSeen = {}
local markerWalkLive = {}
local markerWalkLiveNext = {}

local function resetMarkerWalk()
  table.clear(previousNearbyIds)
  markerWalkFull = true
  markerWalkClusters = nil
  table.clear(markerWalkMarkers)
  table.clear(markerWalkIndicesById)
  table.clear(markerWalkFocus)
  table.clear(markerWalkVisit)
  table.clear(markerWalkSeen)
  table.clear(markerWalkLive)
  table.clear(markerWalkLiveNext)
end

local function markerWalkAdd(i)
  if i and not markerWalkSeen[i] then
    markerWalkSeen[i] = true
    markerWalkVisit[#markerWalkVisit + 1] = i
  end
end

local function beginMarkerWalk(clusters)
  table.clear(markerWalkLiveNext)
  if markerWalkFull or clusters ~= markerWalkClusters then
    markerWalkFull = false
    markerWalkClusters = clusters
    -- Stock owns marker disposal and replaces the cluster table on a clear.
    table.clear(markerWalkMarkers)
    table.clear(markerWalkIndicesById)
    table.clear(markerWalkFocus)
    for i, cluster in ipairs(clusters) do
      -- Drag triggers can share IDs; all entries must retain cluster order.
      local indices = markerWalkIndicesById[cluster.id]
      if not indices then
        indices = {}
        markerWalkIndicesById[cluster.id] = indices
      end
      indices[#indices + 1] = i
    end
    return true
  end
  table.clear(markerWalkVisit)
  table.clear(markerWalkSeen)
  for id in pairs(nearbyIds) do
    local indices = markerWalkIndicesById[id]
    if indices then
      for _, i in ipairs(indices) do markerWalkAdd(i) end
    end
  end
  for _, i in ipairs(markerWalkFocus) do markerWalkAdd(i) end
  for i in pairs(markerWalkLive) do markerWalkAdd(i) end
  table.sort(markerWalkVisit)
  return false
end

local function displayMissionMarkers(level, dtSim, dtReal)
  vehicles.beginFrame()
  profilerPushEvent("MissionMarker precalc")
  local multiseatActive = core_multiseat
    and core_multiseat.isMultiseatActive
    and core_multiseat.isMultiseatActive()
    or false
  if multiseatActive then
    if not multiseatInteractionActive then
      prompt.closeForMultiseat()
      multiseatInteractionActive = true
    end
    displayMultiseatTriggers(dtReal)
    markerWalkFull = true
    profilerPopEvent("MissionMarker precalc")
    return
  elseif multiseatInteractionActive then
    multiseatInteractionActive = false
    table.clear(multiseatActiveMarkers)
    prompt.requestPromptReevaluation()
  end

  local activeMission = overhaul_integration_services_missions_missionManager.getForegroundMissionId()
  local globalAlpha = 1
  if activeMission then
    globalAlpha = 0
  end
  veh = getPlayerVehicle(0)

  if veh then
    updateData.veh = veh
    updateData.vehPos = updateData.vehPos or vec3()
    updateData.vehPos:set(veh:getPositionXYZ())
    updateData.vehPos2d = updateData.vehPos2d or vec3()
    updateData.vehPos2d:set(updateData.vehPos)
    updateData.vehPos2d.z = 0
    updateData.vehVelocity = updateData.vehVelocity or vec3()
    updateData.vehVelocity:set(veh:getVelocityXYZ())

    local vehId = veh:getID()
    updateData.bbCenter = updateData.bbCenter or vec3()
    updateData.bbCenter:set(be:getObjectOOBBCenterXYZ(vehId))
    updateData.bbHalfAxis0 = updateData.bbHalfAxis0 or vec3()
    updateData.bbHalfAxis0:set(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
    updateData.bbHalfAxis1 = updateData.bbHalfAxis1 or vec3()
    updateData.bbHalfAxis1:set(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
    updateData.bbHalfAxis2 = updateData.bbHalfAxis2 or vec3()
    updateData.bbHalfAxis2:set(be:getObjectOOBBHalfAxisXYZ(vehId, 2))

    updateData.bbPoints = vehicles.getBBPoints(updateData.bbCenter, updateData.bbHalfAxis0, updateData.bbHalfAxis1, updateData.bbHalfAxis2)

    updateData.highestBBPointZ = math.max(updateData.bbPoints[2].z, math.max(updateData.bbPoints[3].z, math.max(updateData.bbPoints[6].z, updateData.bbPoints[7].z)))
    vehicles.syncPlayerVehicles(vehId)
  else
    updateData.veh = nil
    vehicles.clearPlayerVehicles()
  end

  updateData.camPos = updateData.camPos or vec3()
  updateData.camPos:set(core_camera.getPositionXYZ())
  -- Dedicated vector: applyVehBB writes playerPosition in place and must not mutate vehPos/camPos.
  updateData.playerPosition = updateData.playerPosition or vec3()
  if veh then
    updateData.playerPosition:set(updateData.vehPos)
  else
    updateData.playerPosition:set(updateData.camPos)
  end

  local playerVelocity = getVelocity(dtSim, updateData.playerPosition)
  -- this is 64 garbage
  updateData.isWalking = gameplay_walk and gameplay_walk.isWalking() or false

  profilerPushEvent("MissionEnter parkingSpeedFactor")
  local parkingSpeedFactor, isAtParkingSpeed, parkingSpeedChanged = getParkingSpeedFactor(playerVelocity)
  local cruisingSpeedFactor, isAtcruisingSpeed, cruisingSpeedChanged = getCruisingSpeedFactor(playerVelocity)


  profilerPopEvent("MissionEnter parkingSpeedFactor")
  -- put reference for icon manager in
  updateData.parkingSpeedFactor = parkingSpeedFactor
  updateData.cruisingSpeedFactor = cruisingSpeedFactor
  updateData.dt = dtReal
  updateData.globalAlpha = globalAlpha
  updateData.camRot = updateData.camRot or quat()
  updateData.camRot:set(core_camera.getQuatXYZW())
  updateData.bigMapActive = freeroam_bigMapMode.bigMapActive()
  updateData.bigmapTransitionActive = freeroam_bigMapMode.isTransitionActive()
  updateData.isFreeCam = commands.isFreeCamera()
  updateData.windowAspectRatio = screenRatio
  updateData.screenHeight = screenHeight
  -- TODO: Clean this up
  table.clear(nearbyIds)
  -- hide all the markers behind the camera
  local maxRadius = 100
  profilerPushEvent("MissionEnter QTStuff")
      -- transitioning or normal play mode
  if   (not freeroam_bigMapMode.bigMapActive())
    or (freeroam_bigMapMode.bigMapActive() and freeroam_bigMapMode.isTransitionActive()) then
    local clusterQt = gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree()
    if markerVehiclesLib.isQueryableClusterQt(clusterQt) and updateData.playerPosition then
      -- Stock nearby set around the seated vehicle / player position.
      for id in clusterQt:queryNotNested(updateData.playerPosition.x-maxRadius, updateData.playerPosition.y-maxRadius, updateData.playerPosition.x+maxRadius, updateData.playerPosition.y + maxRadius) do
        nearbyIds[id] = true
      end
      -- Coupled extras only add markers in their small local bubble.
      if #vehicles.playerVehIds > 1 then
        vehicles.queryClustersNearSecondaryPlayerVehicles(clusterQt, nearbyIds)
      end

      if updateData.isFreeCam and updateData.camPos then
        for id in clusterQt:queryNotNested(updateData.camPos.x-maxRadius, updateData.camPos.y-maxRadius, updateData.camPos.x+maxRadius, updateData.camPos.y + maxRadius) do
          nearbyIds[id] = true
        end
      end
    end
  end

  if M.navigationPoiId  then
    nearbyIds[M.navigationPoiId] = true
  end

  local nearbyChanged = false
  for id in pairs(nearbyIds) do
    if not previousNearbyIds[id] then nearbyChanged = true; break end
  end
  if not nearbyChanged then
    for id in pairs(previousNearbyIds) do
      if not nearbyIds[id] then nearbyChanged = true; break end
    end
  end
  if nearbyChanged then
    table.clear(previousNearbyIds)
    for id in pairs(nearbyIds) do previousNearbyIds[id] = true end
    extensions.hook("onOverhaulNearbyPoiSetChanged")
  end
  profilerPopEvent("MissionEnter QTStuff")
  profilerPopEvent("MissionEnter precalc")


  table.clear(decals)

  local decalCount = 0
  local careerActive = (overhaul_career_career and overhaul_career_career.isActive())
  local tutorialActive = gameplay_discover_freeroamTutorial_tutorial ~= nil
  table.clear(interactableElements)
  local showMissionMarkers = markersVisibleTemporary
  markerVisibilityBySetting.showMissionMarkers = (careerActive or tutorialActive or settings.getValue("showMissionMarkers"))
  -- draw/show all visible markers.
  --[[
  if not timeSincePlayerTeleport then
    timeSincePlayerTeleport = objectTeleported(updateData.camPos, lastCamPos, playerVelLast, dtReal) and 0.5
  end
  if timeSincePlayerTeleport then
    timeSincePlayerTeleport = timeSincePlayerTeleport - dtReal
    if timeSincePlayerTeleport <= 0 then timeSincePlayerTeleport = nil end
  end]]
  local anyMarkerIsInAreaChanged = false
  local anyAreaChanged = false
  local clusters = gameplay_playmodeMarkers.getPlaymodeClusters()
  local poiGeneration = gameplay_rawPois.getRawPoiGeneration()
  local fullWalk = beginMarkerWalk(clusters)
  for n = 1, fullWalk and #clusters or #markerWalkVisit do
    local i = fullWalk and n or markerWalkVisit[n]
    local cluster = clusters[i]
    local marker = markerWalkMarkers[i]
    if not marker then
      marker = gameplay_playmodeMarkers.getMarkerForCluster(cluster)
      markerWalkMarkers[i] = marker
    end
    if fullWalk and marker.focus then markerWalkFocus[#markerWalkFocus + 1] = i end
    if nearbyIds[cluster.id] or marker.focus then
      markerWalkLiveNext[i] = true
      -- Check if the marker should be visible
      cluster.focus = cluster.focus or cluster.id == M.navigationPoiId
      local showMarker = isServiceCluster(cluster) and not photoModeOpen
      and not (editor and editor.active)
      and (showMissionMarkers or cluster.focus)
      showMarker = showMarker and (not cluster.visibleBySetting or markerVisibilityBySetting[cluster.visibleBySetting] or cluster.focus)
      if showMarker then
        -- debug drawing for testing
        marker:show()
        local secondaryHit, primaryHit = vehicles.updateMarkerForPlayerVehicles(marker, cluster.pos)
        anyAreaChanged = anyAreaChanged or marker.isInAreaChanged
        local playerSnap = secondaryHit and vehicles.takePlayerBBSnap() or nil
        -- post-marker decals, so they can be all drawn at once

        -- TODO: optimize
        if marker.groundDecalData then
          if marker.groundDecalData.texture then
            decalCount = decalCount + 1
            decals[decalCount] = marker.groundDecalData
          else
            for _, decal in ipairs(marker.groundDecalData) do
              decalCount = decalCount + 1
              decals[decalCount] = decal
            end
          end
        end

        if veh then
          if not freeroam_bigMapMode.bigMapActive() and not activeMission then
            if marker.interactInPlayMode then
            -- todo: optimize this
              if updateData.isWalking and marker.isInAreaChanged then
                anyMarkerIsInAreaChanged = marker.isInAreaChanged
              end
              vehicles.collectMarkerInteractables(marker, secondaryHit, primaryHit, playerSnap, isAtParkingSpeed, updateData.isWalking, parkingSpeedChanged)
            end
            if marker.interactWhileMoving then
              marker:interactWhileMoving(updateData)
            end
          end
        end
      else
        marker:hide()
      end
    else
      marker:hide()
    end
  end
  if anyAreaChanged then extensions.hook("onOverhaulPoiAreaChanged") end
  markerWalkLive, markerWalkLiveNext = markerWalkLiveNext, markerWalkLive
  if gameplay_rawPois.getRawPoiGeneration() ~= poiGeneration then markerWalkFull = true end
  lastCamPos:set(updateData.camPos)
  if veh then
    playerVelLast:set(be:getObjectVelocityXYZ(veh:getID()))
  end
  prompt.update(interactableElements, updateData.isWalking, isAtParkingSpeed, parkingSpeedChanged, activeMission, anyMarkerIsInAreaChanged, dtReal)
  Engine.Render.DynamicDecalMgr.addDecals(decals, decalCount)
end

local pos2Offset = vec3(0, 0, 1000)
local columnColor = ColorF(1,1,1,1)
local missingPlaymodeStateFrames = 0
local PLAYMODE_CLEAR_GRACE_FRAMES = 5

local function asNavVec3(value)
  if value == nil then return nil end
  local valueType = type(value)
  if valueType == "cdata" then return value end
  if valueType == "table" then
    if value.x and value.y and value.z then
      return vec3(value.x, value.y, value.z)
    end
    if value[1] and value[2] and value[3] then
      return vec3(value[1], value[2], value[3])
    end
  end
  return nil
end

local function getActiveRoutePath()
  local planner = core_groundMarkers and core_groundMarkers.routePlanner
  local path = planner and planner.path
  if path and path[1] and path[1].pos then
    return path
  end
  return nil
end

local function getNavColumnPos()
  local planner = core_groundMarkers and core_groundMarkers.routePlanner
  if planner and planner.getNextFixedWP then
    local nextFixed = asNavVec3(planner:getNextFixedWP())
    if nextFixed then return nextFixed end
  end
  if core_groundMarkers.getTargetPos then
    local target = asNavVec3(core_groundMarkers.getTargetPos())
    if target then return target end
  end
  local endWP = core_groundMarkers and core_groundMarkers.endWP
  if type(endWP) == "table" then
    return asNavVec3(endWP[#endWP] or endWP[1])
  end
  return asNavVec3(endWP)
end

local function drawDistanceColumn(targetPos)
  local camPos = core_camera.getPosition()
  local dist = camPos:distance(targetPos)
  local radius = math.max(dist/400, 0.1)
  local targetPos2 = targetPos + pos2Offset
  local alpha = clamp((dist-50)/200, 0.1, 0.6)
  columnColor.alpha = alpha
  debugDrawer:drawCylinder(targetPos, targetPos2, radius, columnColor)
end

local function resetForceVisible()
  -- Set all markers forceVisible to false
  for i, cluster in ipairs(gameplay_playmodeMarkers.getPlaymodeClusters()) do
    if string.startswith(cluster.id, "missionMarker") then
      cluster.focus = false
    end
  end

  M.reachedTargetPos = nil
  M.navigationPoiId = nil
end

local adoptedStockReachedPos

local function reachedTarget()
  if not core_groundMarkers.clearPathOnReachingTarget then return end
  if settings.getValue("showMissionMarkers") or (overhaul_career_career and overhaul_career_career.isActive()) then
    resetForceVisible()
  end
  local endWP = core_groundMarkers.endWP
  M.reachedTargetPos = type(endWP) == "table" and asNavVec3(endWP[1]) or nil
  extensions.hook("onReachedTargetPos")
  ui_message("bigmap.info.reachedTarget", nil, "bigmapTarget", "checkmark")
end


local function onPreRender(dtReal, dtSim)
  if not isOverhaulActive() then markerWalkFull = true return end
  local playmodeOk = gameplay_playmodeMarkers.isStateWithPlaymodeMarkers()
  if playmodeOk then
    missingPlaymodeStateFrames = 0
  else
    missingPlaymodeStateFrames = missingPlaymodeStateFrames + 1
    if missingPlaymodeStateFrames >= PLAYMODE_CLEAR_GRACE_FRAMES then
      gameplay_playmodeMarkers.clear()
    end
  end

  profilerPushEvent("MissionEnter onPreRender")
  profilerPushEvent("MissionEnter groundMarkers")
  -- Keep the destination column up whenever a route exists. Stock only draws it
  -- when clearPathOnReachingTarget is set, and treats an empty planner (length 0)
  -- as arrival, which wipes nav after a map/UI hitch.
  if overhaul_integration_services_missions_missionManager then
    if overhaul_integration_services_missions_missionManager.getForegroundMissionId() == nil
      and core_groundMarkers and core_groundMarkers.currentlyHasTarget
      and core_groundMarkers.currentlyHasTarget()
      and freeroam_bigMapMode and not freeroam_bigMapMode.bigMapActive() then
      local columnPos = getNavColumnPos()
      if columnPos then
        drawDistanceColumn(columnPos)
      end
      local path = getActiveRoutePath()
      local remaining = path and path[1] and path[1].distToTarget
      if core_groundMarkers.clearPathOnReachingTarget and remaining ~= nil and remaining < 7 then
        reachedTarget()
      end
    end
    -- freeroam_bigMapMode.teleportToPoi marks the arrival on the game's module.
    local stockReachedPos = gameplay_markerInteraction and gameplay_markerInteraction.reachedTargetPos
    if stockReachedPos and stockReachedPos ~= adoptedStockReachedPos then
      adoptedStockReachedPos = stockReachedPos
      M.reachedTargetPos = stockReachedPos
    end
    if M.reachedTargetPos then
      local veh = getPlayerVehicle(0)
      if veh then
        local vehPos = veh:getPosition()
        if vehPos:distance(M.reachedTargetPos) > 20 then
          resetForceVisible()
        end
      end
    end
  end

  profilerPopEvent("MissionEnter groundMarkers")

  local level = playmodeOk and getCurrentLevelIdentifier()
  if level then
    profilerPushEvent("DisplayMissionMarkers")
    displayMissionMarkers(level, dtSim, dtReal)
    profilerPopEvent("DisplayMissionMarkers")
  else
    markerWalkFull = true
  end

  profilerPopEvent("MissionEnter onPreRender")

end


-- Re-run prompt evaluation next frame. Keeps a prompt the player closed closed.
local requestPromptReevaluation = prompt.requestPromptReevaluation

local function clearCache()
  requestPromptReevaluation()
end


-- Keep the stock entrypoint; icon fading is no longer tracked here.
local function skipNextIconFading()
end

local function showMissionMarkersToggled(active)
  gameplay_rawPois.clear()
  freeroam_bigMapPoiProvider.forceSend()
end


local function onAnyMissionChanged(state)
  if not isOverhaulActive() then return end
  freeroam_bigMapPoiProvider.forceSend()
  if state == "started" then
    freeroam_bigMapMode.deselect()
    resetForceVisible()
  end
end

local function onNavigateToMission(poiId)
  if not isOverhaulActive() then return end
  resetForceVisible()
  M.navigationPoiId = poiId
end



local function onClientEndMission(levelPath)
  M.navigationPoiId = nil
  resetMarkerWalk()
  prompt.onClientEndMission()
end

local function onExtensionUnloaded()
  resetMarkerWalk()
  prompt.unlockActivityPromptInput()
end
M.onExtensionUnloaded = onExtensionUnloaded
M.disable = function()
  prompt.closeIfVisible()
  onClientEndMission()
  prompt.resetAfterDisable()
end

local function setMarkersVisibleTemporary(visible)
  markersVisibleTemporary = visible
end

M.closeViewDetailPrompt = closeViewDetailPrompt
M.showMissionMarkersToggled = showMissionMarkersToggled
M.setMarkersVisibleTemporary = setMarkersVisibleTemporary

M.restartCurrent = restartCurrent
M.abandonCurrent = abandonCurrent

M.skipNextIconFading = skipNextIconFading
M.onPreRender = onPreRender

M.getClusterMarker = getClusterMarker

M.onNavigateToMission = onNavigateToMission
M.onAnyMissionChanged = onAnyMissionChanged
M.onClientEndMission = function(...)
  if isOverhaulActive() then return onClientEndMission(...) end
end
M.clearCache = clearCache
-- Modules call this after their state or screen changed, so the refreshed
-- prompt is shown even where the player had closed the old one.
M.setForceReevaluateOpenPrompt = function()
  prompt.clearDismissedPrompt()
  requestPromptReevaluation()
end

M.onUIPlayStateChanged = function(enteredPlay)
  if not isOverhaulActive() then return end
  prompt.onUIPlayStateChanged(enteredPlay)
end
-- Extension reloads can reuse the previous export table. Explicitly clear the
-- removed global destination-marker API so hot reload matches a fresh launch.
M.onSetBigmapNavFocus = nil
M.getNavigationDestinationMarkerState = nil
M.setNavigationDestinationTarget = nil
M.clearNavigationDestinationTarget = nil
return M
