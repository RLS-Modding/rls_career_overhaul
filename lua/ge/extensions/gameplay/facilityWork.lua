-- ================================
-- FACILITY WORK
-- ================================
local M = {}
M.dependencies = {'gameplay_sites_sitesManager', 'freeroam_facilities'}

local core_vehicles = require('core/vehicles')
local utils = (function()
    local ok, mod = pcall(require, 'gameplay/events/freeroam/utils')
    return ok and mod or nil
end)()
local core_groundMarkers = (function()
    local ok, mod = pcall(require, 'core/groundMarkers')
    return ok and mod or nil
end)()

-- Trigger naming
local DROP_TRIGGER_PREFIX = "facilityWork_drop"
local SPAWN_ZONE_NAME = "facilityWork_spawnZone"
-- Add more names here if you place additional drop zones.
local DROP_TRIGGER_NAMES = { "facilityWork_drop" }

local function toVec3(v)
    if not v then return vec3(0, 0, 0) end
    if type(v) == "table" then
        local x = v.x or v[1] or 0
        local y = v.y or v[2] or 0
        local z = v.z or v[3] or 0
        return vec3(x, y, z)
    end
    return vec3(v)
end

local function triggerQuat(trigger)
    local rot = trigger:getRotation()
    if not rot then return quat(0, 0, 0, 1) end
    if type(rot) == "table" then
        local x = rot.x or rot[1] or 0
        local y = rot.y or rot[2] or 0
        local z = rot.z or rot[3] or 0
        local w = rot.w or rot[4] or 1
        return quat(x, y, z, w)
    end
    return quat(rot)
end

local function inverseQuat(q)
    local inv = quat(q)
    inv:inverse()
    return inv
end

-- Future: drop-zone distance/containment (leniency, alternate delivery validation).
local function distanceToTriggerBox(point, trigger)
    local pos = toVec3(trigger:getPosition())
    local scale = trigger:getScale()
    local halfX = (scale and scale.x or 5) * 0.5
    local halfY = (scale and scale.y or 5) * 0.5
    local halfZ = (scale and scale.z or 3) * 0.5
    local q = triggerQuat(trigger)
    local toLocal = inverseQuat(q)
    local pLocal = toLocal * (toVec3(point) - pos)
    local dx = math.max(-halfX, math.min(halfX, pLocal.x)) - pLocal.x
    local dy = math.max(-halfY, math.min(halfY, pLocal.y)) - pLocal.y
    local dz = math.max(-halfZ, math.min(halfZ, pLocal.z)) - pLocal.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

local function isPointInsideTriggerBox(point, trigger)
    local pos = toVec3(trigger:getPosition())
    local scale = trigger:getScale()
    local halfX = (scale and scale.x or 5) * 0.5
    local halfY = (scale and scale.y or 5) * 0.5
    local halfZ = (scale and scale.z or 3) * 0.5
    local q = triggerQuat(trigger)
    local toLocal = inverseQuat(q)
    local pLocal = toLocal * (toVec3(point) - pos)
    return math.abs(pLocal.x) <= halfX and math.abs(pLocal.y) <= halfY and math.abs(pLocal.z) <= halfZ
end

-- Config
local materialsById = {}
local facilityConfigs = {}
local configLoaded = false
local configLoadedForLevel = nil

-- Session state
local sessionTotalPay = 0
local sessionTotalRep = 0
local sessionMaterialsMoved = 0
local sessionMultiplier = 1  -- increases per batch (configurable per facility); applied to batch pay
local selectedFacilityId = nil
local preferredBatchSize = nil
local deliveredPropsByZone = {}
local MAX_PERSISTENT_PROPS = 50
local pendingBatchFacilityId = nil

-- Current batch
local currentForkliftId = nil
local currentBatch = nil

local propsInDropZone = {}

-- AI truck
local TRUCK_SPAWN_SPOT_NAME = "facilityWork_truckSpawn"
local TRUCK_ARRIVAL_RADIUS_M = 10
local TRUCK_LOAD_COUNT = 4
local TRUCK_LOADING_BONUS_DEFAULT = 2500
local TRUCK_SPAWN_INTERVAL_REAL_SEC = 300
local FORKLIFT_REPAIR_PENALTY = 500
local BATCH_LOAD_ARRIVAL_RADIUS_M = 12
local TRUCK_PICKUP_ARRIVAL_RADIUS_M = 12
local truckVehicleId = nil
local truckNextSpawnTime = nil
local truckState = nil
local truckRoadNodes = nil
local truckTargetNodeIndex = nil
local truckArrivedAtNodeIndex = nil  -- node index where truck stopped for loading (used for drive-to-end path)
local truckLoadPropIds = {}
local truckFacilityId = nil
local truckLoadingDropTrigger = nil
local TRUCK_BED_LOAD_RADIUS_M = 8  -- semi flatbed extends far behind cab; adjust if too lenient
local propsEligibleForTruckLoad = {}  -- pid -> true, props in zone that can be loaded (from deliveredPropsByZone)
local truckLoadMaterialName = nil  -- material name for UI message, e.g. "TastiCola"
local truckLoadTargetCount = nil   -- number to load (for tasklist), e.g. 4
local selectedZoneNameForTruckLoad = nil  -- zone picked at dispatch so we show "Load N X" before truck arrives

local batchReadyWaitingForkliftExit = false
local truckDispatchedForCurrentBatch = false
local shiftEnded = false  -- true after end shift so requestFacilityWorkState does not re-apply nav/markers/tasklist
local sessionBatchesCompleted = 0  -- truck only spawns after >= firstTruckAfterBatch (release)
local firstTruckAfterBatch = 2     -- set in doStartFacilityWork; dev: 1; release: math.random(2, 4)
local lastDeliveredZoneName = nil  -- zone we just added props to (for excluding from truck load pick)
local excludeLastZoneForTruckLoad = true  -- dev: false (allow load from last zone); release: true (exclude it)

local dropMarkerObjects = {}
local loadZoneMarkerObjects = {}
local currentBatchWaypointPhase = nil -- "to_loading" | "to_delivery"
local truckWaypointPhase = nil -- "to_pickup" | "to_truck"

local function getTotalDeliveredPropsCount()
    local count = 0
    for _, zoneData in pairs(deliveredPropsByZone) do
        count = count + #zoneData.propIds
    end
    return count
end

local function loadConfig()
    local levelId = getCurrentLevelIdentifier()
    if not levelId then return false end
    if configLoaded and configLoadedForLevel == levelId then return true end
    configLoaded = false
    configLoadedForLevel = nil
    local levelInfo = core_levels.getLevelByName(levelId)
    if not levelInfo or not levelInfo.dir then return false end
    local path = levelInfo.dir .. "/facilityWorkConfig.json"
    local data = jsonReadFile(path)
    if not data or not data.materials then return false end
    materialsById = data.materials
    facilityConfigs = {}
    for k, v in pairs(data) do
        if k ~= "materials" and type(v) == "table" and v.organizationId and v.spawns then
            facilityConfigs[k] = v
        end
    end
    configLoaded = true
    configLoadedForLevel = levelId
    return true
end

local function getForkliftSpawnPoint(spotName)
    local targetName = spotName or "facilityWork_vehicle"
    local levelId = getCurrentLevelIdentifier()
    if not levelId then return nil end
    local sitesPath = (gameplay_sites_sitesManager and gameplay_sites_sitesManager.getCurrentLevelSitesFileByName and gameplay_sites_sitesManager.getCurrentLevelSitesFileByName('roleplay')) or nil
    if not sitesPath and core_levels and core_levels.getLevelByName then
        local levelInfo = core_levels.getLevelByName(levelId)
        if levelInfo and levelInfo.dir then
            sitesPath = levelInfo.dir .. "/facilities/delivery/roleplay.sites.json"
        end
    end
    if not sitesPath then return nil end
    local sites = (gameplay_sites_sitesManager and gameplay_sites_sitesManager.loadSites(sitesPath, true, true)) or jsonReadFile(sitesPath)
    if not sites then return nil end
    local parking = sites.parkingSpots
    if parking then
        for _, spot in ipairs(parking) do
            local name = spot.name or (spot.objects and spot.objects[1] and spot.objects[1].name)
            if name == targetName then
                local pos = spot.pos or (spot.vertices and spot.vertices[1])
                local rot = spot.rot or spot.rotation
                if pos then
                    return { pos = toVec3(pos), rot = rot and quat(rot) or quat(0,0,0,1) }
                end
            end
        end
    end
    local raw = jsonReadFile(sitesPath)
    if raw and raw.parkingSpots then
        for _, spot in ipairs(raw.parkingSpots) do
            local name = spot.name or (spot.objects and spot.objects[1] and spot.objects[1].name)
            if name == targetName then
                local pos = spot.pos or (spot.vertices and spot.vertices[1])
                local rot = spot.rot or spot.rotation
                if pos then
                    return { pos = toVec3(pos), rot = rot and quat(rot) or quat(0,0,0,1) }
                end
            end
        end
    end

    return nil
end

local function getSpawnZoneVertices(zoneName)
    local targetName = zoneName or SPAWN_ZONE_NAME
    local levelId = getCurrentLevelIdentifier()
    if not levelId then return nil end
    local sitesPath = (gameplay_sites_sitesManager and gameplay_sites_sitesManager.getCurrentLevelSitesFileByName and gameplay_sites_sitesManager.getCurrentLevelSitesFileByName('roleplay')) or nil
    if not sitesPath and core_levels and core_levels.getLevelByName then
        local levelInfo = core_levels.getLevelByName(levelId)
        if levelInfo and levelInfo.dir then
            sitesPath = levelInfo.dir .. "/facilities/delivery/roleplay.sites.json"
        end
    end
    if not sitesPath then return nil end
    local sites = (gameplay_sites_sitesManager and gameplay_sites_sitesManager.loadSites(sitesPath, true, true)) or jsonReadFile(sitesPath)
    if not sites then return nil end
    local zones = sites.zones
    if not zones or #zones == 0 then
        local raw = jsonReadFile(sitesPath)
        zones = raw and raw.zones or nil
    end
    if not zones or #zones == 0 then return nil end
    for _, z in ipairs(zones) do
        local name = z.name or (z.objects and z.objects[1] and z.objects[1].name)
        if name == targetName and z.vertices and #z.vertices >= 3 then
            return z.vertices
        end
    end
    return nil
end

local function isPointInPolygon2D(px, py, vertexList)
    if not vertexList or #vertexList < 3 then return false end
    local n = #vertexList
    local crossings = 0
    for i = 1, n do
        local j = (i % n) + 1
        local v1 = vertexList[i]
        local v2 = vertexList[j]
        local x1 = v1[1] or v1.x
        local y1 = v1[2] or v1.y
        local x2 = v2[1] or v2.x
        local y2 = v2[2] or v2.y
        if (y1 > py) ~= (y2 > py) then
            local t = (py - y1) / (y2 - y1)
            local x = x1 + t * (x2 - x1)
            if px < x then crossings = crossings + 1 end
        end
    end
    return (crossings % 2) == 1
end

local function computeSpawnPositionsInZone(vertexList, count, spacing)
    spacing = tonumber(spacing) or 2
    if spacing <= 0 then spacing = 1 end
    if not vertexList or #vertexList < 3 then return {} end
    local minX, maxX = math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge
    local sumX, sumY, sumZ = 0, 0, 0
    local nV = 0
    for _, v in ipairs(vertexList) do
        local x = v[1] or v.x
        local y = v[2] or v.y
        local z = v[3] or v.z or 0
        minX = math.min(minX, x)
        maxX = math.max(maxX, x)
        minY = math.min(minY, y)
        maxY = math.max(maxY, y)
        sumX = sumX + x
        sumY = sumY + y
        sumZ = sumZ + z
        nV = nV + 1
    end
    local baseZ = sumZ / nV
    local centerX = sumX / nV
    local centerY = sumY / nV
    local candidates = {}
    local x = minX
    while x <= maxX do
        local y = minY
        while y <= maxY do
            if isPointInPolygon2D(x, y, vertexList) then
                table.insert(candidates, { x = x, y = y })
            end
            y = y + spacing
        end
        x = x + spacing
    end
    if #candidates == 0 then return {} end
    -- Keep props clustered: sort by distance to zone center and take nearest positions
    local cx, cy = centerX, centerY
    table.sort(candidates, function(a, b)
        local da = (a.x - cx) * (a.x - cx) + (a.y - cy) * (a.y - cy)
        local db = (b.x - cx) * (b.x - cx) + (b.y - cy) * (b.y - cy)
        return da < db
    end)
    local chosen = {}
    for i = 1, math.min(count, #candidates) do
        chosen[i] = candidates[i]
    end
    for i = #chosen, 2, -1 do
        local j = math.random(1, i)
        chosen[i], chosen[j] = chosen[j], chosen[i]
    end
    local positions = {}
    for i = 1, #chosen do
        local c = chosen[i]
        table.insert(positions, vec3(c.x, c.y, baseZ))
    end
    return positions
end

local function getZoneCenter(vertexList)
    if not vertexList or #vertexList == 0 then return nil end
    local sx, sy, sz = 0, 0, 0
    local c = 0
    for _, v in ipairs(vertexList) do
        local x = v[1] or v.x
        local y = v[2] or v.y
        local z = v[3] or v.z or 0
        if x and y then
            sx = sx + x
            sy = sy + y
            sz = sz + z
            c = c + 1
        end
    end
    if c == 0 then return nil end
    return vec3(sx / c, sy / c, sz / c)
end

-- Returns list of spawn zone names for a facility (spawnZones array or single spawnZone)
local function getFacilitySpawnZoneNames(cfg)
    if not cfg then return {} end
    if cfg.spawnZones and type(cfg.spawnZones) == "table" and #cfg.spawnZones > 0 then
        return cfg.spawnZones
    end
    local single = cfg.spawnZone or SPAWN_ZONE_NAME
    return single and { single } or {}
end

local function getFacilityLoadZoneVertices(facilityId)
    if not facilityId then return nil end
    local cfg = facilityConfigs[facilityId]
    if not cfg then return nil end
    local names = getFacilitySpawnZoneNames(cfg)
    for _, name in ipairs(names) do
        local verts = getSpawnZoneVertices(name)
        if verts then return verts end
    end
    return nil
end

local function getFacilityLoadZoneCenter(facilityId)
    return getZoneCenter(getFacilityLoadZoneVertices(facilityId))
end

local function getForkliftPosition()
    if not currentForkliftId then return nil end
    local obj = be:getObjectByID(currentForkliftId)
    if not obj or not obj.getPosition then return nil end
    return toVec3(obj:getPosition())
end

local function isPointNear(pointA, pointB, radius)
    if not pointA or not pointB then return false end
    local r = radius or 5
    local dx = pointA.x - pointB.x
    local dy = pointA.y - pointB.y
    local dz = pointA.z - pointB.z
    return (dx * dx + dy * dy + dz * dz) <= (r * r)
end

local function isForkliftInLoadZone(facilityId)
    local pos = getForkliftPosition()
    if not pos then return false end
    local cfg = facilityId and facilityConfigs[facilityId]
    if not cfg then return false end
    local names = getFacilitySpawnZoneNames(cfg)
    for _, name in ipairs(names) do
        local verts = getSpawnZoneVertices(name)
        if verts and isPointInPolygon2D(pos.x, pos.y, verts) then return true end
    end
    return false
end

local function setNavigationPath(targetPos)
    if not core_groundMarkers or not core_groundMarkers.setPath then return end
    if targetPos then
        core_groundMarkers.setPath(toVec3(targetPos), { clearPathOnReachingTarget = false })
    else
        core_groundMarkers.setPath(nil)
    end
end

local function resolveDropTriggers(triggerNames)
    local out = {}
    if not triggerNames or type(triggerNames) ~= "table" then return out end
    for _, name in ipairs(triggerNames) do
        if type(name) == "string" and name ~= "" then
            local obj = scenetree.findObject(name)
            if obj and obj.getId then
                out[name] = obj
            end
        end
    end
    return out
end

local function getRoadNodes(roadName)
    if not roadName or roadName == "" then return nil end
    local road = scenetree.findObject(roadName)
    if not road or (road.getClassName and road:getClassName() ~= "DecalRoad") then return nil end
    local nodeCount = (road.getNodeCount and road:getNodeCount()) or 0
    if not nodeCount or nodeCount < 1 then return nil end
    local nodes = {}
    for i = 0, nodeCount - 1 do
        local pos = road:getNodePosition(i)
        if pos then
            table.insert(nodes, { x = pos.x, y = pos.y, z = pos.z })
        end
    end
    return #nodes > 0 and nodes or nil
end

local function buildScriptPath(nodes, fromIdx, toIdx)
    if not nodes or fromIdx < 1 or toIdx > #nodes or fromIdx > toIdx then return nil end
    local script = {}
    for i = fromIdx, toIdx do
        local n = nodes[i]
        if n then
            local x = n.x or n[1] or 0
            local y = n.y or n[2] or 0
            local z = n.z or n[3] or 0
            table.insert(script, { x = x, y = y, z = z })
        end
    end
    return #script > 0 and script or nil
end

local function serializeScriptPath(script)
    if not script or #script == 0 then return "{}" end
    local parts = {}
    for _, p in ipairs(script) do
        local x = p.x or p[1] or 0
        local y = p.y or p[2] or 0
        local z = p.z or p[3] or 0
        table.insert(parts, string.format("{x=%s,y=%s,z=%s}", x, y, z))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function sendTruckDriveScript(vehObj, scriptPath, opts)
    if not vehObj or not scriptPath or #scriptPath == 0 then return end
    local serialized = (type(serialize) == "function" and serialize(scriptPath)) or serializeScriptPath(scriptPath)
    local optStr = (opts and opts.startFromCurrentPosition) and ", startFromCurrentPosition = true" or ""
    vehObj:queueLuaCommand("if not ai then extensions.load('ai') end")
    vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")
    vehObj:queueLuaCommand("if ai.setAvoidCars then ai.setAvoidCars('off') end")
    vehObj:queueLuaCommand("ai.driveUsingPath({ script = " .. serialized .. ", avoidCars = 'off', routeSpeedMode = 'limit', routeSpeed = 14, aggression = 0.2" .. optStr .. " })")
end

local function sendTruckStop(vehObj)
    if not vehObj then return end
    vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
    vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
end

-- Drive from current position to target (no teleport). Used for exit leg to avoid script-path jump.
local function sendTruckDriveToPosition(vehObj, targetPos)
    if not vehObj or not targetPos then return end
    local x = targetPos.x or targetPos[1] or 0
    local y = targetPos.y or targetPos[2] or 0
    local z = targetPos.z or targetPos[3] or 0
    -- Pass vec3(...) so driver gets same type as loading (getPointToPointPath expects vec3, not table)
    local posStr = string.format("vec3(%s,%s,%s)", x, y, z)
    print("[facilityWork] truck AI: sendTruckDriveToPosition exit target " .. string.format("%.1f, %.1f, %.1f", x, y, z))
    vehObj:queueLuaCommand('if not driver then extensions.load("driver") end')
    vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")
    vehObj:queueLuaCommand("if ai and ai.setPullOver then ai.setPullOver(false) end")
    -- Leave stop mode so driver's path is followed (overrideAI in stop mode never applies throttle)
    vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('manual') end")
    if core_jobsystem and core_jobsystem.create then
        core_jobsystem.create(function(job)
            job.sleep(0.5)
            print("[facilityWork] truck AI: queueing setAvoidCars off and driver.returnTargetPosition")
            vehObj:queueLuaCommand("if ai.setAvoidCars then ai.setAvoidCars('off') end")
            job.sleep(0.1)
            vehObj:queueLuaCommand('driver.returnTargetPosition(' .. posStr .. ', false, "limit", true)')  -- posStr is vec3(x,y,z)
        end)
    else
        vehObj:queueLuaCommand("if ai.setAvoidCars then ai.setAvoidCars('off') end")
        vehObj:queueLuaCommand('driver.returnTargetPosition(' .. posStr .. ', false, "limit", true)')
    end
end

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
    if scenetree and scenetree.MissionGroup then
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
            -- For inward-facing mode, each corner directly faces the center.
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

local function showLoadZoneMarkers(facilityId, opts)
    local cfg = facilityId and facilityConfigs[facilityId]
    if not cfg then return end
    local zoneNames = getFacilitySpawnZoneNames(cfg)
    if #zoneNames == 0 then return end
    opts = opts or {}
    local markerOptsBase = {}
    for k, v in pairs(opts) do markerOptsBase[k] = v end

    for zoneIndex, zoneName in ipairs(zoneNames) do
        local vertices = getSpawnZoneVertices(zoneName)
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

                -- Match drop-off marker style with a clean oriented box.
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

                local markerOpts = {}
                for k, v in pairs(markerOptsBase) do markerOpts[k] = v end
                markerOpts.clear = (zoneIndex == 1)
                placeCornerMarkers(corners, vecY, markerOpts, tostring(facilityId or "fac") .. "_" .. tostring(zoneName))
            end
        end
    end
end

local function refreshGuidanceMarkers()
    clearDropMarkers()
    if currentBatch then
        showLoadZoneMarkers(currentBatch.facilityId, { clear = true, color = "0.23 0.72 1.00 1", prefix = "loadingMarker", markerList = loadZoneMarkerObjects })
        if currentBatch.dropTrigger then
            showDropMarkers(currentBatch.dropTrigger, { clear = false, color = "0.6 0.9 0.23 1", prefix = "deliveryMarker", markerList = dropMarkerObjects, label = "delivery marker" })
        end
    end

    if truckState == "waiting_for_load" then
        if truckLoadingDropTrigger then
            showDropMarkers(truckLoadingDropTrigger, { clear = false, color = "1.00 0.80 0.16 1", prefix = "truckPickupMarker", markerList = dropMarkerObjects, label = "truck pickup marker" })
        end
    end
end

local function getSessionMultiplierHeaderLabel()
    local mult = sessionMultiplier
    local multStr = (mult == math.floor(mult)) and tostring(mult) or string.format("%.1f", mult)
    return "On duty: x" .. multStr
end

local function setTasklistOnDuty()
    guihooks.trigger('SetTasklistHeader', { label = getSessionMultiplierHeaderLabel() })
    guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_pay", label = "Total pay: $0", type = "message", clear = false })
    guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_rep", label = "Total rep: 0", type = "message", clear = false })
end

local function isFacilityWorkAvailable()
    if not loadConfig() then return false end
    for _, cfg in pairs(facilityConfigs) do
        local names = getFacilitySpawnZoneNames(cfg)
        for _, zoneName in ipairs(names) do
            local verts = getSpawnZoneVertices(zoneName)
            if verts and #verts >= 3 then return true end
        end
    end
    return false
end

local function getAvailableFacilities()
    if not loadConfig() then return {} end
    local list = {}
    for id, cfg in pairs(facilityConfigs) do
        table.insert(list, {
            id = id,
            name = cfg.name or id,
            batchSize = cfg.batchSize or 8
        })
    end
    return list
end

local function getFacilityWorkState()
    return {
        onDuty = (currentBatch ~= nil or currentForkliftId ~= nil),
        sessionTotalPay = sessionTotalPay,
        sessionTotalRep = sessionTotalRep,
        sessionMaterialsMoved = sessionMaterialsMoved,
        available = isFacilityWorkAvailable(),
        facilities = getAvailableFacilities(),
        selectedFacilityId = selectedFacilityId,
        preferredBatchSize = preferredBatchSize,
        truckWaitingForLoad = (truckState == "waiting_for_load")
    }
end

local function notifyPhoneState()
    guihooks.trigger('updateFacilityWorkState', getFacilityWorkState())
end

local function updateTasklistValues()
    guihooks.trigger('SetTasklistHeader', { label = getSessionMultiplierHeaderLabel() })
    guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_pay", label = "Total pay: $" .. sessionTotalPay, type = "message", clear = false })
    guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_rep", label = "Total rep: " .. sessionTotalRep, type = "message", clear = false })

    -- Next-stop line removed; multiplier is shown in task list header instead.
    guihooks.trigger('SetTasklistTask', { id = "facilityWork_next_stop", label = "", type = "message", clear = true })

    if truckState == "driving_to_pickup" or truckState == "waiting_for_load" then
        if truckLoadMaterialName and truckLoadTargetCount then
            local loadLabel = string.format("Load %d %s onto the truck", truckLoadTargetCount, truckLoadMaterialName)
            if currentBatch then
                loadLabel = "Finish your current batch, then " .. loadLabel
            end
            guihooks.trigger('SetTasklistTask', { id = "facilityWork_truck_load", label = loadLabel, type = "message", clear = false })
        else
            guihooks.trigger('SetTasklistTask', { id = "facilityWork_truck_load", label = "", type = "message", clear = true })
        end
    else
        guihooks.trigger('SetTasklistTask', { id = "facilityWork_truck_load", label = "", type = "message", clear = true })
    end
    notifyPhoneState()
end

local function setBatchWaypointPhase(phase, opts)
    opts = opts or {}
    if not currentBatch then
        currentBatchWaypointPhase = nil
        return
    end

    if phase == "to_loading" then
        local loadCenter = getFacilityLoadZoneCenter(currentBatch.facilityId)
        if loadCenter then
            currentBatchWaypointPhase = "to_loading"
            setNavigationPath(loadCenter)
        end
    elseif phase == "to_delivery" then
        if currentBatch.dropTrigger then
            currentBatchWaypointPhase = "to_delivery"
            setNavigationPath(currentBatch.dropTrigger:getPosition())
        end
    else
        currentBatchWaypointPhase = nil
    end

    refreshGuidanceMarkers()
    updateTasklistValues()

    if not opts.silent and utils and utils.displayMessage then
        if phase == "to_loading" then
            utils.displayMessage("Waypoint updated: go to loading area first.", 3)
        elseif phase == "to_delivery" then
            utils.displayMessage("Waypoint updated: deliver to the drop area.", 3)
        end
    end
end

local function setTruckWaypointPhase(phase, opts)
    opts = opts or {}
    if phase == "to_pickup" then
        if truckLoadingDropTrigger then
            truckWaypointPhase = "to_pickup"
            setNavigationPath(truckLoadingDropTrigger:getPosition())
        end
    elseif phase == "to_truck" then
        local truckObj = truckVehicleId and be:getObjectByID(truckVehicleId) or nil
        if truckObj then
            truckWaypointPhase = "to_truck"
            setNavigationPath(truckObj:getPosition())
        end
    else
        truckWaypointPhase = nil
    end

    refreshGuidanceMarkers()
    updateTasklistValues()

    if not opts.silent and utils and utils.displayMessage then
        if phase == "to_pickup" then
            utils.displayMessage("Waypoint updated: pick up materials first.", 3)
        elseif phase == "to_truck" then
            utils.displayMessage("Waypoint updated: load materials onto the truck.", 3)
        end
    end
end

local function setWaypointToFacilityForklift(facilityId)
    if not loadConfig() then return false end
    local facCfg = facilityConfigs[facilityId]
    if not facCfg then return false end
    local spawnData = getForkliftSpawnPoint(facCfg.parkingSpot)
    if not spawnData then
        spawnData = getForkliftSpawnPoint("facilityWork_vehicle")
    end
    if not spawnData then return false end
    setNavigationPath(spawnData.pos)
    clearDropMarkers()
    showLoadZoneMarkers(facilityId, { clear = true, color = "0.23 0.72 1.00 1", prefix = "loadingMarker", markerList = loadZoneMarkerObjects })
    return true
end

local function spawnBatch(facilityId)
    if not loadConfig() then return false end
    local facCfg = facilityConfigs[facilityId]
    if not facCfg then return false end

    local zoneNames = getFacilitySpawnZoneNames(facCfg)
    if #zoneNames == 0 then return false end
    local triggerNames = (facCfg.triggers and #facCfg.triggers > 0) and facCfg.triggers or DROP_TRIGGER_NAMES
    local resolved = resolveDropTriggers(triggerNames)
    local dropList = {}
    for n in pairs(resolved) do table.insert(dropList, n) end
    if #dropList == 0 then return false end
    local dropName = dropList[math.random(1, #dropList)]
    local dropTrigger = resolved[dropName]
    if not dropTrigger then return false end
    local spawns = facCfg.spawns or {}
    if #spawns == 0 then return false end
    local baseSize = tonumber(facCfg.batchSize) or 8
    local batchSize = preferredBatchSize or baseSize
    batchSize = math.max(1, batchSize)
    
    local spawnDef = spawns[math.random(1, #spawns)]
    local mat = materialsById[spawnDef.materialId]
    if not mat or not mat.model_key or not mat.config then return false end

    local propIds = {}
    local moneyPerProp = {}
    local repPerProp = {}
    local spacing = mat.spawnGridSpacing or 2
    -- Collect spawn positions from all configured zones (each zone can contribute up to batchSize)
    local allPositions = {}
    for _, zoneName in ipairs(zoneNames) do
        local vertices = getSpawnZoneVertices(zoneName)
        if vertices and #vertices >= 3 then
            local zonePositions = computeSpawnPositionsInZone(vertices, batchSize, spacing)
            for _, p in ipairs(zonePositions) do
                table.insert(allPositions, p)
            end
        end
    end
    for i = #allPositions, 2, -1 do
        local j = math.random(1, i)
        allPositions[i], allPositions[j] = allPositions[j], allPositions[i]
    end
    local positions = {}
    for i = 1, math.min(batchSize, #allPositions) do
        positions[i] = allPositions[i]
    end
    local numToSpawn = #positions
    if numToSpawn == 0 then return false end
    local spawnRotationZDeg = tonumber(facCfg.spawnRotationZ)
    if spawnRotationZDeg == nil then spawnRotationZDeg = 0 end
    local rotZ = quatFromEuler(0, 0, math.rad(spawnRotationZDeg))
    local baseRot = quatFromDir(vec3(0, 1, 0))

    for i = 1, numToSpawn do
        local pos = positions[i]
        if not pos then break end
        local rot = rotZ * baseRot
        local obj = core_vehicles.spawnNewVehicle(mat.model_key, {
            pos = pos,
            rot = rot,
            config = mat.config,
            autoEnterVehicle = false
        })
        if obj then
            local pid = obj:getID()
            table.insert(propIds, pid)
            table.insert(moneyPerProp, mat.money or 0)
            table.insert(repPerProp, math.floor((mat.money or 0) / 100))
            -- Apply rotation after a delay so spawn/init scripts don't overwrite it. Use current position
            -- (where physics put the prop) so overlapping props can spread out and land instead of being snapped back.
            local applyRot = rot
            if core_jobsystem and core_jobsystem.create then
                core_jobsystem.create(function(job)
                    job.sleep(0.18)
                    local o = be:getObjectByID(pid)
                    if o then
                        local currentPos = o.getPosition and toVec3(o:getPosition()) or pos
                        if o.setPositionRotation then
                            o:setPositionRotation(currentPos.x, currentPos.y, currentPos.z, applyRot.x, applyRot.y, applyRot.z, applyRot.w)
                        elseif o.setPosRot then
                            o:setPosRot(currentPos.x, currentPos.y, currentPos.z, applyRot.x, applyRot.y, applyRot.z, applyRot.w)
                        end
                    end
                end)
            else
                if obj.setPositionRotation then
                    obj:setPositionRotation(pos.x, pos.y, pos.z, applyRot.x, applyRot.y, applyRot.z, applyRot.w)
                elseif obj.setPosRot then
                    obj:setPosRot(pos.x, pos.y, pos.z, applyRot.x, applyRot.y, applyRot.z, applyRot.w)
                end
            end
        end
    end

    if #propIds == 0 then return false end

    truckDispatchedForCurrentBatch = false
    currentBatchWaypointPhase = nil
    currentBatch = {
        facilityId = facilityId,
        dropTrigger = dropTrigger,
        propIds = propIds,
        moneyPerProp = moneyPerProp,
        repPerProp = repPerProp,
        organizationId = facCfg.organizationId,
        materialName = mat.name or spawnDef.materialId or "materials"
    }
    return true
end

local function despawnBatch()
    if not currentBatch then return end
    clearDropMarkers()
    for _, pid in ipairs(currentBatch.propIds) do
        local obj = be:getObjectByID(pid)
        if obj then
            obj:delete()
        end
    end
    currentBatchWaypointPhase = nil
    currentBatch = nil
end

local function clearTruckState()
    if truckVehicleId then
        local obj = be:getObjectByID(truckVehicleId)
        if obj then obj:delete() end
        truckVehicleId = nil
    end
    for _, pid in ipairs(truckLoadPropIds) do
        local obj = be:getObjectByID(pid)
        if obj then obj:delete() end
    end
    table.clear(truckLoadPropIds)
    table.clear(propsEligibleForTruckLoad)
    truckLoadMaterialName = nil
    truckLoadTargetCount = nil
    selectedZoneNameForTruckLoad = nil
    truckWaypointPhase = nil
    truckState = nil
    truckRoadNodes = nil
    truckTargetNodeIndex = nil
    truckArrivedAtNodeIndex = nil
    truckFacilityId = nil
    truckLoadingDropTrigger = nil
end

local function getCurrentBatchZoneName()
    if not currentBatch or not currentBatch.dropTrigger then return nil end
    return currentBatch.dropTrigger:getName()
end

local function pickTruckLoadZone()
    local candidateZones = {}
    local currentZoneName = getCurrentBatchZoneName()
    for zName, data in pairs(deliveredPropsByZone) do
        if data.trigger and #data.propIds > 0 then
            -- Exclude zone that is current batch's drop target (not cleared until batch is finished)
            if zName ~= currentZoneName then
                table.insert(candidateZones, { name = zName, data = data })
            end
        end
    end
    -- Exclude last delivered zone when picking (release); dev: set excludeLastZoneForTruckLoad = false
    local pickFrom = candidateZones
    if excludeLastZoneForTruckLoad and lastDeliveredZoneName and #candidateZones > 1 then
        local filtered = {}
        for _, c in ipairs(candidateZones) do
            if c.name ~= lastDeliveredZoneName then
                table.insert(filtered, c)
            end
        end
        if #filtered > 0 then pickFrom = filtered end
    end
    local selectedZoneName = nil
    local selectedZoneData = nil
    if #pickFrom > 0 then
        local chosen = pickFrom[math.random(1, #pickFrom)]
        selectedZoneName = chosen.name
        selectedZoneData = chosen.data
    end
    return selectedZoneName, selectedZoneData
end

local function applyWaitingForLoadState()
    table.clear(truckLoadPropIds)
    table.clear(propsEligibleForTruckLoad)
    truckLoadingDropTrigger = nil
    local selectedZoneData = nil
    local currentZoneName = getCurrentBatchZoneName()
    -- Only use pre-selected zone if it exists and is cleared (not the current batch's drop zone)
    if selectedZoneNameForTruckLoad and selectedZoneNameForTruckLoad ~= currentZoneName and deliveredPropsByZone[selectedZoneNameForTruckLoad] then
        selectedZoneData = deliveredPropsByZone[selectedZoneNameForTruckLoad]
    else
        truckLoadMaterialName = nil
        truckLoadTargetCount = nil
        selectedZoneNameForTruckLoad = nil
        local zoneName, zoneData = pickTruckLoadZone()
        if zoneData then
            selectedZoneNameForTruckLoad = zoneName
            selectedZoneData = zoneData
            truckLoadingDropTrigger = zoneData.trigger
        else
            -- Fallback: current drop zone is the only zone (shouldn't happen with 2–4 batch rule; handle BeamNG edge cases)
            if currentZoneName and deliveredPropsByZone[currentZoneName] and #deliveredPropsByZone[currentZoneName].propIds > 0 then
                selectedZoneNameForTruckLoad = currentZoneName
                selectedZoneData = deliveredPropsByZone[currentZoneName]
                truckLoadingDropTrigger = selectedZoneData.trigger
            end
        end
    end
    if selectedZoneData then
        truckLoadMaterialName = selectedZoneData.materialName or "materials"
        truckLoadTargetCount = math.min(TRUCK_LOAD_COUNT, #selectedZoneData.propIds)
        truckLoadingDropTrigger = selectedZoneData.trigger
        for _, pid in ipairs(selectedZoneData.propIds) do
            propsEligibleForTruckLoad[pid] = true
        end
        if utils and utils.displayMessage then
            utils.displayMessage(string.format("Load %d %s onto the truck.", truckLoadTargetCount, truckLoadMaterialName), 5)
        end
    end
    if truckLoadingDropTrigger then
        if not currentBatch then
            setTruckWaypointPhase("to_pickup", { silent = true })
        else
            -- Player still has a batch: keep batch drop zone waypoint; only show truck pickup markers (no path change)
            refreshGuidanceMarkers()
            updateTasklistValues()
        end
    else
        truckWaypointPhase = nil
        setNavigationPath(nil)
        refreshGuidanceMarkers()
        updateTasklistValues()
    end
end

local function spawnTruckAndDriveToPickup(facilityId)
    if truckState then return false end
    if not loadConfig() then return false end
    local facCfg = facilityConfigs[facilityId]
    if not facCfg then return false end
    if not facCfg.aiPickupRoadName then return false end
    local nodes = getRoadNodes(facCfg.aiPickupRoadName)
    if not nodes or #nodes == 0 then return false end
    local pickupIndex1 = tonumber(facCfg.aiPickupNodeIndex) or 18
    local pickupIndex0 = math.max(0, math.min(pickupIndex1 - 1, #nodes - 1))
    local driveToPickup = (facCfg.driveToPickup ~= false)
    local spotName = facCfg.truckSpawnSpot or ("facilityWork_truckSpawn_" .. facilityId)
    local spawnData = getForkliftSpawnPoint(spotName)
    if not spawnData then
        spawnData = getForkliftSpawnPoint("facilityWork_truckSpawn")
    end
    if not spawnData then
        spawnData = getForkliftSpawnPoint("facilityWork_vehicle")
    end
    if not spawnData then return false end
    local truckCfg = facCfg.truck or {}
    local model = truckCfg.model or "md_series"
    local config = truckCfg.config or "md_60_flatbed"
    local vehObj = core_vehicles.spawnNewVehicle(model, {
        pos = spawnData.pos,
        rot = spawnData.rot,
        config = config,
        autoEnterVehicle = false
    })
    if not vehObj then return false end
    truckVehicleId = vehObj:getID()
    truckRoadNodes = nodes
    truckTargetNodeIndex = pickupIndex0
    truckFacilityId = facilityId

    if driveToPickup then
        truckState = "driving_to_pickup"
        truckWaypointPhase = nil
        local zoneName, zoneData = pickTruckLoadZone()
        if zoneData then
            selectedZoneNameForTruckLoad = zoneName
            truckLoadingDropTrigger = zoneData.trigger
            truckLoadMaterialName = zoneData.materialName or "materials"
            truckLoadTargetCount = math.min(TRUCK_LOAD_COUNT, #zoneData.propIds)
            updateTasklistValues()
        end
        refreshGuidanceMarkers()
        local scriptToPickup = buildScriptPath(nodes, 1, pickupIndex0 + 1)
        if scriptToPickup then
            if core_jobsystem and core_jobsystem.create then
                core_jobsystem.create(function(job)
                    job.sleep(0.5)
                    local v = be:getObjectByID(truckVehicleId)
                    if v and truckState == "driving_to_pickup" then
                        sendTruckDriveScript(v, scriptToPickup)
                    end
                end)
            else
                sendTruckDriveScript(vehObj, scriptToPickup)
            end
        end
    else
        truckState = "waiting_for_load"
        applyWaitingForLoadState()
    end
    return true
end

local function payoutBatchAndSpawnNext()
    if not currentBatch then return end
    local propIds = currentBatch.propIds
    local moneyPerProp = currentBatch.moneyPerProp
    local repPerProp = currentBatch.repPerProp
    local facilityId = currentBatch.facilityId

    local totalMoney = 0
    local totalRep = 0
    for i = 1, #propIds do
        totalMoney = totalMoney + (moneyPerProp[i] or 0)
        totalRep = totalRep + (repPerProp[i] or 0)
    end
    -- Session multiplier (increases per batch; configurable per facility)
    totalMoney = math.floor(totalMoney * sessionMultiplier)
    local mult = 1
    if career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
        mult = career_economyAdjuster.getSectionMultiplier("facilityWork") or 1
    end
    totalMoney = math.floor(totalMoney * mult)
    sessionTotalPay = sessionTotalPay + totalMoney
    sessionTotalRep = sessionTotalRep + totalRep
    sessionMaterialsMoved = sessionMaterialsMoved + #propIds

    if currentBatch.dropTrigger then
        local zoneName = currentBatch.dropTrigger:getName()
        local matName = currentBatch.materialName or "materials"
        if not deliveredPropsByZone[zoneName] then
            deliveredPropsByZone[zoneName] = { trigger = currentBatch.dropTrigger, propIds = {}, materialName = matName }
        end
        deliveredPropsByZone[zoneName].materialName = matName
        for _, pid in ipairs(propIds) do
            table.insert(deliveredPropsByZone[zoneName].propIds, pid)
        end
        lastDeliveredZoneName = zoneName
    end

    -- Future: optional LRU/oldest-zone culling when over MAX_PERSISTENT_PROPS.
    local currentTotal = getTotalDeliveredPropsCount()
    if currentTotal > MAX_PERSISTENT_PROPS then
        for zName, data in pairs(deliveredPropsByZone) do
            while #data.propIds > 0 and currentTotal > MAX_PERSISTENT_PROPS do
                local pid = table.remove(data.propIds, 1)
                local obj = be:getObjectByID(pid)
                if obj then obj:delete() end
                currentTotal = currentTotal - 1
            end
            if currentTotal <= MAX_PERSISTENT_PROPS then break end
        end
    end

    truckLoadingDropTrigger = nil
    table.clear(propsInDropZone)
    currentBatchWaypointPhase = nil
    currentBatch = nil
    clearDropMarkers()

    -- Increase session multiplier for next batch (per-facility config)
    local facCfg = facilityId and facilityConfigs[facilityId]
    local perBatch
    if facCfg then
        perBatch = tonumber(facCfg.sessionMultiplierPerBatch) or 0.5
    else
        perBatch = 0.5
    end
    sessionMultiplier = sessionMultiplier + perBatch

    updateTasklistValues()

    sessionBatchesCompleted = sessionBatchesCompleted + 1

    local truckSpawned = false
    local roadNodes = facCfg and facCfg.aiPickupRoadName and getRoadNodes(facCfg.aiPickupRoadName)
    if facCfg and facCfg.aiPickupRoadName and roadNodes and #roadNodes > 0 then
        if not truckState and sessionBatchesCompleted >= firstTruckAfterBatch and getTotalDeliveredPropsCount() >= TRUCK_LOAD_COUNT then
            spawnTruckAndDriveToPickup(facilityId)
            truckSpawned = true
            -- Only apply loading zone here: batch is already cleared above, so we never overwrite current drop zone/path.
            -- (Early dispatch does not call applyWaitingForLoadState; zone/path apply when truck arrives.)
            if not currentBatch then
                applyWaitingForLoadState()
            end
            if utils and utils.displayMessage then
                utils.displayMessage("Truck arriving. Load from the marked area.", 4)
            end
        end
    end

    if truckState or truckSpawned then
        pendingBatchFacilityId = facilityId
        -- Batch just cleared; re-apply load zone so previously "current" zone can now be used (highlight + propsEligibleForTruckLoad)
        if truckState == "waiting_for_load" or truckState == "driving_to_pickup" then
            applyWaitingForLoadState()
        end
        -- only clear path when we have no loading zone to show (avoid clearing path we just set)
        if not truckLoadingDropTrigger then
            setNavigationPath(nil)
        end
    else
        if facilityId and spawnBatch(facilityId) then
            setBatchWaypointPhase("to_loading", { silent = true })
        end
    end
end

-- End shift
local function endShiftCleanup()
    setNavigationPath(nil)
    if currentBatch then
        for _, pid in ipairs(currentBatch.propIds) do
            local obj = be:getObjectByID(pid)
            if obj then obj:delete() end
        end
        currentBatch = nil
    end
    for _, zoneData in pairs(deliveredPropsByZone) do
        for _, pid in ipairs(zoneData.propIds) do
            local obj = be:getObjectByID(pid)
            if obj then obj:delete() end
        end
    end
    if currentForkliftId then
        local obj = be:getObjectByID(currentForkliftId)
        if obj then
            if be:getPlayerVehicleID(0) == currentForkliftId then
                local pos = toVec3(obj:getPosition())
                if gameplay_walk and gameplay_walk.setWalkingMode then
                    gameplay_walk.setWalkingMode(true, pos)
                end
            end
            obj:delete()
        end
        currentForkliftId = nil
    end
    clearTruckState()
    truckNextSpawnTime = nil
    pendingBatchFacilityId = nil
    truckDispatchedForCurrentBatch = false
    sessionBatchesCompleted = 0

    deliveredPropsByZone = {}
    lastDeliveredZoneName = nil
    table.clear(propsInDropZone)
    currentBatchWaypointPhase = nil
    truckWaypointPhase = nil
    clearDropMarkers()
    batchReadyWaitingForkliftExit = false

    if career_career and career_career.isActive() and (sessionTotalPay ~= 0 or sessionTotalRep ~= 0) then
        local orgId = nil
        if selectedFacilityId and facilityConfigs[selectedFacilityId] then
            orgId = facilityConfigs[selectedFacilityId].organizationId
        end
        if career_modules_payment and career_modules_payment.reward then
            local rewardData = {
                money = { amount = sessionTotalPay },
                beamXP = { amount = math.floor(sessionTotalPay / 10) }
            }
            if orgId and sessionTotalRep ~= 0 then
                rewardData[orgId .. "Reputation"] = { amount = sessionTotalRep }
            end
            career_modules_payment.reward(rewardData, {
                label = string.format("Facility work (shift): $%d | Rep +%d | %d materials", sessionTotalPay, sessionTotalRep, sessionMaterialsMoved),
                tags = {"facilityWork", "gameplay"}
            }, true)
        end
        if career_saveSystem and career_saveSystem.saveCurrent then
            career_saveSystem.saveCurrent()
        end
    end

    if utils and utils.displayMessage then
        local msg = string.format("Shift ended. Total earned: $%d | Rep: %d | Materials moved: %d",
            sessionTotalPay, sessionTotalRep, sessionMaterialsMoved)
        utils.displayMessage(msg, 6)
    end

    sessionTotalPay = 0
    sessionTotalRep = 0
    sessionMaterialsMoved = 0

    shiftEnded = true
    guihooks.trigger('ClearTasklist')
    notifyPhoneState()
    if utils and utils.restoreTrafficAmount then
        utils.restoreTrafficAmount()
    end
end

local function doStartFacilityWork()
    shiftEnded = false
    configLoaded = false
    configLoadedForLevel = nil
    if not loadConfig() then
        if utils and utils.displayMessage then
            utils.displayMessage("Facility work: config not loaded (wrong level or missing facilityWorkConfig.json).", 5)
        end
        return false
    end
    local facilityId = selectedFacilityId
    if not facilityId or not facilityConfigs[facilityId] then
        facilityId = next(facilityConfigs)
        selectedFacilityId = facilityId
    end
    if not facilityId then
        if utils and utils.displayMessage then
            utils.displayMessage("Facility work: no facility config found.", 5)
        end
        return false
    end
    sessionBatchesCompleted = 0
    firstTruckAfterBatch = math.random(2, 4)
    local facCfg = facilityConfigs[facilityId]
    local zoneNames = getFacilitySpawnZoneNames(facCfg)
    if #zoneNames == 0 then
        if utils and utils.displayMessage then
            utils.displayMessage("Facility work: no spawn zone(s) configured.", 8)
        end
        return false
    end
    local hasValidZone = false
    for _, zName in ipairs(zoneNames) do
        local vertices = getSpawnZoneVertices(zName)
        if vertices and #vertices >= 3 then hasValidZone = true; break end
    end
    if not hasValidZone then
        if utils and utils.displayMessage then
            utils.displayMessage("Facility work: spawn zone(s) '"..table.concat(zoneNames, "', '").."' not found in roleplay.sites.json.", 8)
        end
        return false
    end
    local triggerNames = (facCfg.triggers and #facCfg.triggers > 0) and facCfg.triggers or DROP_TRIGGER_NAMES
    local resolved = resolveDropTriggers(triggerNames)
    local dropList = {}
    for n in pairs(resolved) do table.insert(dropList, n) end
    if #dropList == 0 then
        if utils and utils.displayMessage then
            utils.displayMessage("Facility work: no drop trigger found. Add trigger names under \"triggers\" in facilityWorkConfig.json for this facility, or place a BeamNGTrigger named 'facilityWork_drop' with luaFunction onBeamNGTrigger.", 8)
        end
        return false
    end
    if currentBatch then
        despawnBatch()
    end
    for _, zoneData in pairs(deliveredPropsByZone) do
        for _, pid in ipairs(zoneData.propIds) do
            local obj = be:getObjectByID(pid)
            if obj then obj:delete() end
        end
    end
    deliveredPropsByZone = {}
    lastDeliveredZoneName = nil
    table.clear(propsInDropZone)
    currentBatchWaypointPhase = nil
    truckWaypointPhase = nil
    batchReadyWaitingForkliftExit = false
    pendingBatchFacilityId = nil
    if not spawnBatch(facilityId) then
        if utils and utils.displayMessage then
            utils.displayMessage("Facility work: could not spawn batch (check spawn zone and drop trigger).", 5)
        end
        return false
    end
    local spawnData = getForkliftSpawnPoint(facCfg.parkingSpot)
    if not spawnData then
        if utils and utils.displayMessage then
            local sName = facCfg.parkingSpot or "facilityWork_vehicle"
            utils.displayMessage("Facility work error: '"..sName.."' parking spot not found in roleplay.sites.json.", 6)
        end
        despawnBatch()
        return false
    end
    local vehInfo = facCfg.vehicle or {}
    local model = vehInfo.model or "forklift"
    local config = vehInfo.config or "standard"
    local vehObj = core_vehicles.spawnNewVehicle(model, {
        pos = spawnData.pos,
        rot = spawnData.rot,
        config = config,
        autoEnterVehicle = false
    })
    
    if vehObj then
        currentForkliftId = vehObj:getID()
    else
        if utils and utils.displayMessage then
            utils.displayMessage("Facility work error: failed to spawn forklift.", 5)
        end
        despawnBatch()
        return false
    end

    if utils and utils.saveAndSetTrafficAmount then
        utils.saveAndSetTrafficAmount(0)
    end
    -- Session multiplier: start at facility's base, increases per batch
    sessionMultiplier = (tonumber(facCfg.sessionMultiplierBase) or 1)
    setTasklistOnDuty()
    setBatchWaypointPhase("to_loading", { silent = true })
    if utils and utils.displayMessage then
        utils.displayMessage("On duty. Waypoint set to loading area first, then delivery. Trucks arrive after you complete a batch.", 6)
    end

    -- comment out for dev mode (release: truck only after first batch)
    -- Truck spawns after first batch is delivered (payoutBatchAndSpawnNext).

    -- comment out for dev mode (release: truck only after firstTruckAfterBatch completions)
    -- if facCfg and facCfg.aiPickupRoadName then
    --     spawnTruckAndDriveToPickup(facilityId)
    -- end

    return true
end

local function repairForklift()
    if not currentForkliftId or not loadConfig() then return false end
    local facilityId = selectedFacilityId
    if not facilityId or not facilityConfigs[facilityId] then return false end
    local facCfg = facilityConfigs[facilityId]
    local vehInfo = facCfg.vehicle or {}
    local model = vehInfo.model or "forklift"
    local config = vehInfo.config or "standard"
    local oldVehObj = be:getObjectByID(currentForkliftId)
    if not oldVehObj then return false end

    local vehicleData = { config = config, keepOtherVehRotation = true }
    local newVehObj = core_vehicles.replaceVehicle(model, vehicleData, oldVehObj)
    if not newVehObj then
        if utils and utils.displayMessage then
            utils.displayMessage("Forklift repair failed.", 4)
        end
        return false
    end

    currentForkliftId = newVehObj:getID()
    newVehObj:queueLuaCommand("extensions.load('individualRepair')")
    if core_vehicleBridge and core_vehicleBridge.executeAction then
        core_vehicleBridge.executeAction(newVehObj, 'initPartConditions', {}, 0, 1, 1)
    end
    be:enterVehicle(0, newVehObj)

    local penalty = FORKLIFT_REPAIR_PENALTY
    if career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
        penalty = math.floor(penalty * (career_economyAdjuster.getSectionMultiplier("facilityWork") or 1))
    end
    sessionTotalPay = math.max(0, sessionTotalPay - penalty)
    setTasklistOnDuty()
    updateTasklistValues()

    if Engine and Engine.Audio and Engine.Audio.playOnce then
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Vehicle_Recover')
    end
    if utils and utils.displayMessage then
        utils.displayMessage("Forklift repaired. $" .. tostring(penalty) .. " deducted from session pay.", 4)
    end
    if truckState == "waiting_for_load" then
        setTruckWaypointPhase(truckWaypointPhase or "to_pickup", { silent = true })
    elseif currentBatch then
        if currentBatchWaypointPhase == "to_delivery" then
            setBatchWaypointPhase("to_delivery", { silent = true })
        else
            setBatchWaypointPhase("to_loading", { silent = true })
        end
    else
        refreshGuidanceMarkers()
    end

    return true
end

local function onBeamNGTrigger(data)
    local triggerName = data.triggerName
    local event = data.event
    if triggerName and triggerName:find(DROP_TRIGGER_PREFIX) then
        if event == "enter" then
            if currentBatch and currentForkliftId then
                local subjectId = data.subjectID
                for _, pid in ipairs(currentBatch.propIds) do
                    if pid == subjectId then
                        propsInDropZone[subjectId] = true
                        local countIn = 0
                        for _ in pairs(propsInDropZone) do countIn = countIn + 1 end
                        if countIn >= #currentBatch.propIds then
                            batchReadyWaitingForkliftExit = true
                            if utils and utils.displayMessage then
                                utils.displayMessage("All items delivered. Drive out of the drop zone to complete.", 4)
                            end
                        end
                        local facilityId = currentBatch.facilityId
                        local threshold = math.max(1, #currentBatch.propIds - 1)
                        if not truckDispatchedForCurrentBatch and not truckState and sessionBatchesCompleted >= firstTruckAfterBatch and countIn >= threshold and facilityId then
                            local facCfg = facilityConfigs[facilityId]
                            if facCfg and facCfg.aiPickupRoadName and getRoadNodes(facCfg.aiPickupRoadName) and #(getRoadNodes(facCfg.aiPickupRoadName) or {}) > 0 then
                                if getTotalDeliveredPropsCount() + #currentBatch.propIds >= TRUCK_LOAD_COUNT then
                                    if spawnTruckAndDriveToPickup(facilityId) then
                                        truckDispatchedForCurrentBatch = true
                                        updateTasklistValues()
                                    end
                                end
                            end
                        end
                        break
                    end
                end
            end
        elseif event == "exit" then
            if batchReadyWaitingForkliftExit and currentBatch and currentForkliftId and data.subjectID == currentForkliftId then
                batchReadyWaitingForkliftExit = false
                payoutBatchAndSpawnNext()
            end
        end
        return
    end
end

local function onVehicleSwitched(_oldId, newId)
    -- Future: optional end shift on forklift exit (currently player must use phone).
    if currentBatch and not currentForkliftId and newId then
        currentForkliftId = newId
    end
end

local function onExtensionLoaded()
    configLoaded = false
    configLoadedForLevel = nil
    shiftEnded = false
    currentBatchWaypointPhase = nil
    truckWaypointPhase = nil
end

local function onExtensionUnloaded()
    if currentBatch then despawnBatch() end
    for _, zoneData in pairs(deliveredPropsByZone) do
        for _, pid in ipairs(zoneData.propIds) do
            local obj = be:getObjectByID(pid)
            if obj then obj:delete() end
        end
    end
    if currentForkliftId then
        local obj = be:getObjectByID(currentForkliftId)
        if obj then obj:delete() end
        currentForkliftId = nil
    end
    clearTruckState()

    deliveredPropsByZone = {}
    lastDeliveredZoneName = nil
    table.clear(propsInDropZone)
    currentBatchWaypointPhase = nil
    truckWaypointPhase = nil
    batchReadyWaitingForkliftExit = false
    clearDropMarkers()
    if utils and utils.restoreTrafficAmount then
        utils.restoreTrafficAmount()
    end
    guihooks.trigger('ClearTasklist')
end

local function onUpdate(_dtReal, _dtSim, _dtRaw)
    if currentBatch and currentBatchWaypointPhase == "to_loading" then
        local loadCenter = getFacilityLoadZoneCenter(currentBatch.facilityId)
        local inLoadZone = isForkliftInLoadZone(currentBatch.facilityId)
        if inLoadZone or (loadCenter and isPointNear(getForkliftPosition(), loadCenter, BATCH_LOAD_ARRIVAL_RADIUS_M)) then
            setBatchWaypointPhase("to_delivery")
        end
    end

    if truckState == "waiting_for_load" and truckWaypointPhase == "to_pickup" and truckLoadingDropTrigger then
        local pickupPos = toVec3(truckLoadingDropTrigger:getPosition())
        local forkliftPos = getForkliftPosition()
        local reachedPickup = forkliftPos and (isPointInsideTriggerBox(forkliftPos, truckLoadingDropTrigger) or isPointNear(forkliftPos, pickupPos, TRUCK_PICKUP_ARRIVAL_RADIUS_M))
        if reachedPickup then
            setTruckWaypointPhase("to_truck")
        end
    end

    if not truckState or not truckRoadNodes or not truckVehicleId then return end
    local vehObj = be:getObjectByID(truckVehicleId)
    if not vehObj then
        clearTruckState()
        refreshGuidanceMarkers()
        notifyPhoneState()
        return
    end
    local pos = vehObj:getPosition()
    local targetNode = truckRoadNodes[truckTargetNodeIndex + 1]
    if not targetNode then return end
    local dx = (targetNode.x or 0) - pos.x
    local dy = (targetNode.y or 0) - pos.y
    local dz = (targetNode.z or 0) - pos.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)

    if truckState == "driving_to_pickup" then
        if dist < TRUCK_ARRIVAL_RADIUS_M then
            sendTruckStop(vehObj)
            truckArrivedAtNodeIndex = truckTargetNodeIndex + 1  -- store node for drive-to-end path
            truckState = "waiting_for_load"
            -- Always apply: populate propsEligibleForTruckLoad, show zone markers, set path (uses pre-selected zone if still valid)
            applyWaitingForLoadState()
            updateTasklistValues()
        end
    elseif truckState == "waiting_for_load" then
        -- Position-only: any eligible prop near the truck counts as loaded (no exit event required)
        local targetCount = truckLoadTargetCount or TRUCK_LOAD_COUNT
        if #truckLoadPropIds < targetCount then
            local truckPos = toVec3(pos)
            local zoneName = truckLoadingDropTrigger and truckLoadingDropTrigger:getName()
            local zoneData = zoneName and deliveredPropsByZone[zoneName]
            for pid, _ in pairs(propsEligibleForTruckLoad) do
                if #truckLoadPropIds >= targetCount then break end
                local propObj = be:getObjectByID(pid)
                if propObj and propObj.getPosition then
                    local propPos = toVec3(propObj:getPosition())
                    local pdx = propPos.x - truckPos.x
                    local pdy = propPos.y - truckPos.y
                    local pdz = propPos.z - truckPos.z
                    local propDist = math.sqrt(pdx * pdx + pdy * pdy + pdz * pdz)
                    if propDist < TRUCK_BED_LOAD_RADIUS_M then
                        table.insert(truckLoadPropIds, pid)
                        propsEligibleForTruckLoad[pid] = nil
                        if zoneData and zoneData.propIds then
                            for i = #zoneData.propIds, 1, -1 do
                                if zoneData.propIds[i] == pid then
                                    table.remove(zoneData.propIds, i)
                                    break
                                end
                            end
                            if #zoneData.propIds == 0 then
                                deliveredPropsByZone[zoneName] = nil
                            end
                        end
                    end
                else
                    propsEligibleForTruckLoad[pid] = nil
                end
            end
        end
    elseif truckState == "driving_to_end" then
        if dist < TRUCK_ARRIVAL_RADIUS_M then
            local facId = truckFacilityId
            local bonus = TRUCK_LOADING_BONUS_DEFAULT
            if facId and facilityConfigs[facId] and facilityConfigs[facId].truckLoadingBonus then
                bonus = tonumber(facilityConfigs[facId].truckLoadingBonus) or bonus
            end
            if career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
                bonus = math.floor(bonus * (career_economyAdjuster.getSectionMultiplier("facilityWork") or 1))
            end
            sessionTotalPay = sessionTotalPay + bonus
            updateTasklistValues()
            clearTruckState()
            truckNextSpawnTime = os.clock() + TRUCK_SPAWN_INTERVAL_REAL_SEC
            
            if utils and utils.displayMessage then
                utils.displayMessage("Truck departed with load. Loading bonus: $" .. tostring(bonus) .. ". Next truck in 5 min.", 5)
            end
            if pendingBatchFacilityId then
                if spawnBatch(pendingBatchFacilityId) then
                    setBatchWaypointPhase("to_loading", { silent = true })
                end
                pendingBatchFacilityId = nil
            end

            notifyPhoneState()
        end
    end
end

function M.requestFacilityWorkState()
    if shiftEnded then
        setNavigationPath(nil)
        clearDropMarkers()
        notifyPhoneState()
        return
    end
    refreshGuidanceMarkers()
    if selectedFacilityId and not currentForkliftId and not currentBatch and not truckState then
        setWaypointToFacilityForklift(selectedFacilityId)
    end
    -- Only show facility work task list when shift has started (on duty)
    if currentBatch or currentForkliftId or truckState then
        updateTasklistValues()
    end
    notifyPhoneState()
end

function M.startFacilityWork()
    return doStartFacilityWork()
end

function M.selectFacility(id)
    loadConfig()
    if id and facilityConfigs[id] then
        selectedFacilityId = id
        if not currentBatch and not currentForkliftId then
            if setWaypointToFacilityForklift(id) and utils and utils.displayMessage then
                utils.displayMessage("Waypoint set to the loaner forklift.", 4)
            end
        end
    else
        selectedFacilityId = nil
        if not currentBatch and not currentForkliftId and not truckState then
            setNavigationPath(nil)
            clearDropMarkers()
        end
    end
    notifyPhoneState()
end

function M.setBatchSize(size)
    local s = tonumber(size)
    if s and s >= 1 then
        preferredBatchSize = math.floor(s)
        notifyPhoneState()
    end
end

function M.endFacilityWork()
    endShiftCleanup()
end

function M.repairForklift()
    return repairForklift()
end

function M.completeTruckLoading()
    if truckState ~= "waiting_for_load" or not truckRoadNodes or #truckRoadNodes == 0 or not truckVehicleId then return end
    local required = truckLoadTargetCount or TRUCK_LOAD_COUNT
    if #truckLoadPropIds < required then
        if utils and utils.displayMessage then
            utils.displayMessage(string.format("Load all %d %s onto the truck first.", required, truckLoadMaterialName or "items"), 4)
        end
        return
    end
    local vehObj = be:getObjectByID(truckVehicleId)
    if not vehObj then
        clearTruckState()
        notifyPhoneState()
        return
    end
    print("[facilityWork] completeTruckLoading: starting drive-to-end (driver.returnTargetPosition)")
    local toIdx = #truckRoadNodes
    local lastNode = truckRoadNodes[toIdx]
    if not lastNode then return end
    truckTargetNodeIndex = toIdx - 1
    truckState = "driving_to_end"
    truckWaypointPhase = nil
    updateTasklistValues()
    -- Use driver.returnTargetPosition (like quarry/loading) so truck drives from current position with no teleport/jump
    local exitPos = {
        x = lastNode.x or lastNode[1] or 0,
        y = lastNode.y or lastNode[2] or 0,
        z = lastNode.z or lastNode[3] or 0
    }
    sendTruckDriveToPosition(vehObj, exitPos)
    if not currentBatch then
        setNavigationPath(nil)
        refreshGuidanceMarkers()
        updateTasklistValues()
    end
    notifyPhoneState()
end

function M.onUpdate(dtReal, dtSim, dtRaw)
    onUpdate(dtReal, dtSim, dtRaw)
end

M.onBeamNGTrigger = onBeamNGTrigger
M.onVehicleSwitched = onVehicleSwitched
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
