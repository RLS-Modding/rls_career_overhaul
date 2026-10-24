-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Facility loading and delivery markers and navigation.
-- The owner supplies live facility data when configuration reloads.
return function(dropMarkerObjects, facilityConfigs, getFacilitySpawnZoneNames,
  getForkliftSpawnPoint, getSpawnZoneVertices, loadConfig, loadZoneMarkerObjects,
  setNavigationPath, toVec3)

  local function createCornerMarker(markerName)
    local marker = createObject('TSStatic')
    marker:setField('shapeName', 0, "art/shapes/interface/position_marker.dae")
    marker:setPosition(vec3(0, 0, 0))
    marker.scale = vec3(1, 1, 1)
    marker:setField('rotation', 0, '1 0 0 0')
    marker.useInstanceRenderData = true
    marker:setField('instanceColor', 0, '1 1 1 1')
    marker:setField('collisionType', 0, "Collision Mesh")
    marker:setField('decalType', 0, "Collision Mesh")
    marker:setField('playAmbient', 0, "1")
    marker:setField('allowPlayerStep', 0, "1")
    marker:setField('canSave', 0, "0")
    marker:setField('canSaveDynamicFields', 0, "1")
    marker:setField('renderNormals', 0, "0")
    marker:setField('meshCulling', 0, "0")
    marker:setField('originSort', 0, "0")
    marker:setField('forceDetail', 0, "-1")
    marker.canSave = false
    marker:registerObject(markerName)
    if scenetree.MissionGroup then
      scenetree.MissionGroup:addObject(marker)
    end
    return marker
  end

  local function safeDelete(obj, objName)
    if not obj then return end
    local success, err = pcall(function()
      local name = obj:getName()
      local found = name and scenetree.findObject(name) or nil
      local sameObject = found and (found == obj or found:getId() == obj:getId())
      if sameObject then
        if editor and editor.onRemoveSceneTreeObjects then
          editor.onRemoveSceneTreeObjects({obj:getId()})
        end
        obj:delete()
      else
        if found then
          if editor and editor.onRemoveSceneTreeObjects then
            editor.onRemoveSceneTreeObjects({found:getId()})
          end
          found:delete()
        end
        if obj:isValid() then
          if editor and editor.onRemoveSceneTreeObjects then
            editor.onRemoveSceneTreeObjects({obj:getId()})
          end
          obj:delete()
        end
      end
    end)
    if not success and objName then
      print(string.format("[facilityWork] Error deleting %s: %s", objName, tostring(err)))
    end
  end

  local function clearMarkerList(markerList, markerLabel)
    for _, obj in ipairs(markerList) do
      safeDelete(obj, markerLabel)
    end
    table.clear(markerList)
  end

  local function clearDropMarkers()
    clearMarkerList(dropMarkerObjects, "drop marker")
    clearMarkerList(loadZoneMarkerObjects, "loading marker")
  end

  local cornerMarkerQOff = quatFromEuler(0, 0, math.pi / 2) * quatFromEuler(0, math.pi / 2, math.pi / 2)
  local cornerMarkerRotations = {
    quatFromEuler(0, 0, math.rad(90)),
    quatFromEuler(0, 0, math.rad(180)),
    quatFromEuler(0, 0, math.rad(270)),
    quatFromEuler(0, 0, 0)
  }

  local function placeCornerMarkers(corners, markerYDir, opts, nameSeed)
    if not corners or #corners == 0 then return end
    opts = opts or {}
    local markerList = opts.markerList or dropMarkerObjects
    if opts.clear ~= false then
      clearMarkerList(markerList, opts.label or "drop marker")
    end
    local color = opts.color or "0.6 0.9 0.23 1"
    local markerPrefix = opts.prefix or "dropMarker"
    local rayUp = opts.upVec or vec3(0, 0, 1)
    local faceCenter = opts.faceCenter == true
    local centerPos = opts.centerPos and toVec3(opts.centerPos) or nil
    local dir = markerYDir and vec3(markerYDir.x, markerYDir.y, markerYDir.z or 0) or vec3(0, 1, 0)
    if dir:squaredLength() < 1e-6 then
      dir = vec3(0, 1, 0)
    else
      dir:normalize()
    end
    local uniqueId = os.time() .. "_" .. math.random(1000, 9999)
    for i, p in ipairs(corners) do
      local markerName = string.format("facilityWork_%s_%s_%d_%s", markerPrefix, nameSeed or "marker", i, uniqueId)
      local hit = Engine.castRay(p + rayUp * 2, p - rayUp * 10, true, false)
      local groundPos = hit and vec3(hit.pt) or (p + rayUp * 0.05)
      groundPos = groundPos + rayUp * 0.05
      local dirForMarker = dir
      if faceCenter and centerPos then
        local toCenter = centerPos - p
        toCenter.z = 0
        if toCenter:squaredLength() > 1e-6 then
          toCenter:normalize()
          dirForMarker = toCenter
        end
      end
      local finalRot
      if faceCenter then
        finalRot = cornerMarkerQOff * quatFromDir(dirForMarker, vec3(0, 0, 1))
      else
        finalRot = cornerMarkerRotations[((i - 1) % 4) + 1] * cornerMarkerQOff * quatFromDir(vec3(0, 0, 1), dirForMarker)
      end
      local marker = createCornerMarker(markerName)
      marker:setPosRot(groundPos.x, groundPos.y, groundPos.z, finalRot.x, finalRot.y, finalRot.z, finalRot.w)
      marker:setField('instanceColor', 0, color)
      table.insert(markerList, marker)
    end
  end

  local function showDropMarkers(trigger, opts)
    if not trigger then return end
    opts = opts or {}
    local triggerPos = trigger:getPosition()
    local triggerRot = trigger:getRotation()
    local triggerScale = trigger:getScale()
    local length = (triggerScale and triggerScale.x or 8) * 0.5
    local width = (triggerScale and triggerScale.y or 6) * 0.5
    local rot = quat(triggerRot)
    local vecX = rot * vec3(1, 0, 0)
    local vecY = rot * vec3(0, 1, 0)
    local vecZ = rot * vec3(0, 0, 1)
    local corners = {
      triggerPos - vecX * length + vecY * width,
      triggerPos + vecX * length + vecY * width,
      triggerPos + vecX * length - vecY * width,
      triggerPos - vecX * length - vecY * width
    }
    local markerOpts = {}
    for k, v in pairs(opts) do markerOpts[k] = v end
    markerOpts.upVec = vecZ
    placeCornerMarkers(corners, vecY, markerOpts, trigger:getName() or "drop")
  end

  local function loadingZoneCorners(pts, center)
    local bestLenSq = -1
    local edgeDir = vec3(1, 0, 0)
    for i = 1, #pts do
      local j = (i % #pts) + 1
      local d = pts[j] - pts[i]
      d.z = 0
      local lenSq = d:squaredLength()
      if lenSq > bestLenSq and lenSq > 1e-6 then
        bestLenSq = lenSq
        d:normalize()
        edgeDir = d
      end
    end
    local vecX = vec3(edgeDir.x, edgeDir.y, 0)
    local vecY = vec3(-vecX.y, vecX.x, 0)
    local minX, maxX = math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge
    local avgZ = 0
    for _, p in ipairs(pts) do
      local rel = p - center
      local lx = rel:dot(vecX)
      local ly = rel:dot(vecY)
      minX = math.min(minX, lx)
      maxX = math.max(maxX, lx)
      minY = math.min(minY, ly)
      maxY = math.max(maxY, ly)
      avgZ = avgZ + p.z
    end
    avgZ = avgZ / #pts
    local function localToWorld(lx, ly)
      return vec3(
        center.x + vecX.x * lx + vecY.x * ly,
        center.y + vecX.y * lx + vecY.y * ly,
        avgZ
      )
    end
    local corners = {
      localToWorld(minX, maxY),
      localToWorld(maxX, maxY),
      localToWorld(maxX, minY),
      localToWorld(minX, minY)
    }
    return corners, vecY
  end

  local function showLoadZoneMarkers(facilityId, opts)
    local cfg = facilityId and facilityConfigs[facilityId]
    if not cfg then return end
    local zoneNames = getFacilitySpawnZoneNames(cfg)
    if #zoneNames == 0 then return end
    opts = opts or {}
    local markerOptsBase = {}
    for k, v in pairs(opts) do markerOptsBase[k] = v end
    for zoneIndex, zoneName in ipairs(zoneNames) do
      local vertices = getSpawnZoneVertices(zoneName, cfg)
      if vertices and #vertices >= 3 then
        local pts = {}
        local center = vec3(0, 0, 0)
        for _, v in ipairs(vertices) do
          local p = toVec3(v)
          table.insert(pts, p)
          center = center + p
        end
        if #pts >= 3 then
          center = center / #pts
          local corners, vecY = loadingZoneCorners(pts, center)
          local markerOpts = {}
          for k, v in pairs(markerOptsBase) do markerOpts[k] = v end
          markerOpts.clear = (zoneIndex == 1)
          placeCornerMarkers(corners, vecY, markerOpts, tostring(facilityId or "fac") .. "_" .. tostring(zoneName))
        end
      end
    end
  end

  local function setWaypointToFacilityForklift(facilityId)
    if not loadConfig() then return false end
    local facCfg = facilityConfigs[facilityId]
    if not facCfg then return false end
    local spawnData = getForkliftSpawnPoint(facCfg.forkliftSpawnSpot or facCfg.parkingSpot, facCfg)
    if not spawnData then return false end
    setNavigationPath(spawnData.pos)
    clearDropMarkers()
    showLoadZoneMarkers(facilityId, { clear = true, color = "0.23 0.72 1.00 1", prefix = "loadingMarker", markerList = loadZoneMarkerObjects })
    return true
  end

  return {clearDropMarkers = clearDropMarkers,
    setWaypointToFacilityForklift = setWaypointToFacilityForklift,
    showDropMarkers = showDropMarkers, showLoadZoneMarkers = showLoadZoneMarkers,
    set_facilityConfigs = function(value) facilityConfigs = value end}
end
