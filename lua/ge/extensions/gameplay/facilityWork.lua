-- ================================
-- FACILITY WORK MODULE (any level)
-- Standalone career module: forklift materials move; reward on forklift exit.
-- Started from phone (no start trigger). Drop trigger: name facilityWork_drop, luaFunction onBeamNGTrigger.
-- Per-level: facilityWorkMaterials.json in level dir; zone facilityWork_spawnZone in roleplay.sites.json.
-- ================================
local M = {}
M.dependencies = {'gameplay_sites_sitesManager', 'freeroam_facilities'}

local core_vehicles = require('core/vehicles')
-- Borrow displayMessage from freeroam utils for trigger feedback (same pattern as gameplay/events/freeroamEvents)
local utils = (function()
    local ok, mod = pcall(require, 'gameplay/events/freeroam/utils')
    return ok and mod or nil
end)()
local core_groundMarkers = (function()
    local ok, mod = pcall(require, 'core/groundMarkers')
    return ok and mod or nil
end)()

local ZONE_LENIENCY_M = 3

-- Trigger naming (level editor; no start trigger - started from phone)
local DROP_TRIGGER_PREFIX = "facilityWork_drop"
local SPAWN_ZONE_NAME = "facilityWork_spawnZone"
-- Explicit drop trigger names (add more if you place additional drop zones)
local DROP_TRIGGER_NAMES = { "facilityWork_drop" }

-- Safe vec3 from engine getPosition() / table (avoids bad argument to _mul)
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

-- Safe quat from trigger getRotation() (engine may return table or userdata)
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

-- Distance from point to oriented box surface (trigger pos/rot/scale). Returns 0 if inside.
local function distanceToTriggerBox(point, trigger)
    local pos = toVec3(trigger:getPosition())
    local scale = trigger:getScale()
    local halfX = (scale and scale.x or 5) * 0.5
    local halfY = (scale and scale.y or 5) * 0.5
    local halfZ = (scale and scale.z or 3) * 0.5
    local q = triggerQuat(trigger)
    local toLocal = q:inverse()
    local pLocal = toLocal * (toVec3(point) - pos)
    local dx = math.max(-halfX, math.min(halfX, pLocal.x)) - pLocal.x
    local dy = math.max(-halfY, math.min(halfY, pLocal.y)) - pLocal.y
    local dz = math.max(-halfZ, math.min(halfZ, pLocal.z)) - pLocal.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- Is point inside trigger box?
local function isPointInsideTriggerBox(point, trigger)
    local pos = toVec3(trigger:getPosition())
    local scale = trigger:getScale()
    local halfX = (scale and scale.x or 5) * 0.5
    local halfY = (scale and scale.y or 5) * 0.5
    local halfZ = (scale and scale.z or 3) * 0.5
    local q = triggerQuat(trigger)
    local toLocal = q:inverse()
    local pLocal = toLocal * (toVec3(point) - pos)
    return math.abs(pLocal.x) <= halfX and math.abs(pLocal.y) <= halfY and math.abs(pLocal.z) <= halfZ
end

-- Config (loaded from current level; invalidated when level changes)
local materialsById = {}
local facilityConfigs = {}
local configLoaded = false
local configLoadedForLevel = nil

-- Session state (persistent across batches in one "on duty" period)
local sessionTotalPay = 0
local sessionTotalRep = 0
local sessionMaterialsMoved = 0
local selectedFacilityId = nil
local preferredBatchSize = nil
-- Delivered materials left in world until shift ends (persistent materials)
local sessionDeliveredVehicles = {}
local MAX_PERSISTENT_PROPS = 50

-- Current batch
local currentForkliftId = nil
local currentBatch = nil  -- { facilityId, dropTrigger, propIds = {}, moneyPerProp = {}, organizationId, repPerProp, materialName }

-- Props that have entered the drop zone this batch (all must be in before we credit/despawn)
local propsInDropZone = {}

-- AI truck: spawn at facilityWork_truckSpawn, drive to node 18 of road, wait for "Complete loading", then drive to last node and despawn
local TRUCK_SPAWN_SPOT_NAME = "facilityWork_truckSpawn"
local TRUCK_ARRIVAL_RADIUS_M = 10
local TRUCK_LOAD_COUNT = 4
local TRUCK_LOADING_BONUS_DEFAULT = 500   -- bonus pay when player completes loading and truck departs
local TRUCK_SPAWN_INTERVAL_REAL_SEC = 300 -- next truck spawns 5 minutes (real time) after previous departs
local truckVehicleId = nil
local truckNextSpawnTime = nil            -- os.clock() when to spawn next truck (nil = no timer)
local truckState = nil  -- "driving_to_pickup" | "waiting_for_load" | "driving_to_end"
local truckRoadNodes = nil  -- { {x,y,z}, ... }
local truckTargetNodeIndex = nil  -- 0-based index of current waypoint
local truckLoadPropIds = {}  -- up to 4 prop IDs reserved for this truck (despawn with truck)
local truckMaterialName = nil  -- for notification "Load 4 of [name]"
local truckFacilityId = nil

-- All items in zone; wait for forklift to exit drop zone before paying out (so player "puts down" and leaves the bay)
local batchReadyWaitingForkliftExit = false

-- Drop triggers cache (name -> scenetree ref)
local dropTriggersByName = {}

-- Drop-zone corner markers (bus.lua-style)
local dropMarkerObjects = {}

-- Fallback level ID to load facilityWorkConfig.json when current level has no config (e.g. custom maps with same zone names).
local CONFIG_FALLBACK_LEVEL = "west_coast_usa"

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
    -- If current level has no config, try fallback level then FS search (mod levels may live under different path)
    if (not data or not data.materials) and core_levels and core_levels.getLevelByName then
        local fallbackInfo = core_levels.getLevelByName(CONFIG_FALLBACK_LEVEL)
        if fallbackInfo and fallbackInfo.dir then
            local fallbackPath = fallbackInfo.dir .. "/facilityWorkConfig.json"
            data = jsonReadFile(fallbackPath)
        end
    end
    if (not data or not data.materials) and FS and FS.findFiles then
        local candidates = FS:findFiles("levels/", "facilityWorkConfig.json", -1, true, false) or {}
        for _, p in ipairs(candidates) do
            local d = jsonReadFile(p)
            if d and d.materials then
                data = d
                break
            end
        end
    end
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

-- Get spawn spot for forklift from roleplay.sites.json (parking spot named "facilityWork_vehicle")
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
    
    -- Look in parkingSpots from sitesManager first
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

    -- If not found in manager, try raw file (in case of cache/stale data)
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

-- Get zone vertices from level sites (roleplay.sites.json). Use game's path resolution so mod level is found.
local function getSpawnZoneVertices(zoneName)
    local targetName = zoneName or SPAWN_ZONE_NAME
    local levelId = getCurrentLevelIdentifier()
    if not levelId then return nil end
    -- Prefer getCurrentLevelSitesFileByName so mod level's roleplay.sites.json is found (same as ambulance/taxi)
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
    -- loadSites may normalize structure (e.g. parkingSpots.objects); zones might be raw array or under .objects
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

-- Point-in-polygon test (XY plane); vertices = { {x,y,z}, ... } or { {x,y}, ... }
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

-- Compute spawn positions inside zone: AABB of polygon, then grid points filtered by point-in-polygon.
-- spacing: grid step; reuses positions if count > grid spots.
local function computeSpawnPositionsInZone(vertexList, count, spacing)
    spacing = spacing or 2
    if not vertexList or #vertexList < 3 then return {} end
    local minX, maxX = math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge
    local sumZ = 0
    for _, v in ipairs(vertexList) do
        local x = v[1] or v.x
        local y = v[2] or v.y
        local z = v[3] or v.z or 0
        minX = math.min(minX, x)
        maxX = math.max(maxX, x)
        minY = math.min(minY, y)
        maxY = math.max(maxY, y)
        sumZ = sumZ + z
    end
    local baseZ = sumZ / #vertexList
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
    -- Shuffle so we don't always use the same corner when candidates > count
    for i = #candidates, 2, -1 do
        local j = math.random(1, i)
        candidates[i], candidates[j] = candidates[j], candidates[i]
    end
    local positions = {}
    -- Fill spots; if count > candidates, reuse spots (force spawn)
    for i = 1, count do
        if #candidates == 0 then break end
        local c = candidates[(i - 1) % #candidates + 1]
        table.insert(positions, vec3(c.x, c.y, baseZ))
    end
    return positions
end

-- Resolve drop triggers by name list. Returns table name -> scenetree ref. Used per-facility when facCfg.triggers is set.
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

-- Get road nodes from a DecalRoad by scenetree name. Returns { {x,y,z}, ... } or nil. Node index in config is 1-based (node 18 = index 18).
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

-- Build script array for ai.driveUsingPath({ script = ... }). Nodes are 1-based table of {x,y,z}. fromIdx, toIdx are 1-based inclusive.
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

-- Serialize script path to Lua table string for vehicle queueLuaCommand.
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

-- Send AI drive using waypoint script: vehicle is teleported to first node then drives along path (ai.driveUsingPath(script)).
local function sendTruckDriveScript(vehObj, scriptPath)
    if not vehObj or not scriptPath or #scriptPath == 0 then return end
    local serialized = (type(serialize) == "function" and serialize(scriptPath)) or serializeScriptPath(scriptPath)
    vehObj:queueLuaCommand("if not ai then extensions.load('ai') end")
    vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")
    vehObj:queueLuaCommand("if ai.setAvoidCars then ai.setAvoidCars('off') end")
    vehObj:queueLuaCommand("ai.driveUsingPath({ script = " .. serialized .. ", avoidCars = 'off', routeSpeedMode = 'limit', routeSpeed = 14 })")
end

-- Stop truck AI (parking brake, stop mode).
local function sendTruckStop(vehObj)
    if not vehObj then return end
    vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
    vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
end

-- Create a corner marker TSStatic for drop-zone visualization.
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

local function clearDropMarkers()
    for _, obj in ipairs(dropMarkerObjects) do
        safeDelete(obj, "drop marker")
    end
    table.clear(dropMarkerObjects)
end

-- Create corner markers for the drop trigger (raycast to ground, bus.lua-style).
local function showDropMarkers(trigger)
    if not trigger then return end
    clearDropMarkers()
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
        { pos = triggerPos - vecX * length + vecY * width },
        { pos = triggerPos + vecX * length + vecY * width },
        { pos = triggerPos + vecX * length - vecY * width },
        { pos = triggerPos - vecX * length - vecY * width }
    }
    local qOff = quatFromEuler(0, 0, math.pi / 2) * quatFromEuler(0, math.pi / 2, math.pi / 2)
    local rotations = {
        quatFromEuler(0, 0, math.rad(90)),
        quatFromEuler(0, 0, math.rad(180)),
        quatFromEuler(0, 0, math.rad(270)),
        quatFromEuler(0, 0, 0)
    }
    local uniqueId = os.time() .. "_" .. math.random(1000, 9999)
    for i, corner in ipairs(corners) do
        local markerName = string.format("facilityWork_dropMarker_%s_%d_%s", trigger:getName() or "drop", i, uniqueId)
        local hit = Engine.castRay(corner.pos + vecZ * 2, corner.pos - vecZ * 10, true, false)
        local groundPos = hit and vec3(hit.pt) or (corner.pos + vecZ * 0.05)
        groundPos = groundPos + vecZ * 0.05
        local finalRot = rotations[i] * qOff * quatFromDir(vec3(0, 0, 1), vecY)
        local marker = createCornerMarker(markerName)
        marker:setPosRot(groundPos.x, groundPos.y, groundPos.z, finalRot.x, finalRot.y, finalRot.z, finalRot.w)
        marker:setField('instanceColor', 0, "0.6 0.9 0.23 1")
        table.insert(dropMarkerObjects, marker)
    end
end

local function setTasklistOnDuty()
    guihooks.trigger('SetTasklistHeader', { label = "On duty" })
    guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_pay", label = "Total pay: $0", type = "message", clear = false })
    guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_rep", label = "Total rep: 0", type = "message", clear = false })
end

-- Phone app: build state for UI (onDuty, session stats, available on this level)
-- Available if config loads and at least one facility has a valid spawn zone. Drop trigger is checked when starting shift.
local function isFacilityWorkAvailable()
    if not loadConfig() then return false end
    for fid, cfg in pairs(facilityConfigs) do
        local zoneName = cfg.spawnZone or SPAWN_ZONE_NAME
        local verts = getSpawnZoneVertices(zoneName)
        if verts and #verts >= 3 then return true end
    end
    return false
end

local function getAvailableFacilities()
    if not loadConfig() then return {} end
    local list = {}
    for id, cfg in pairs(facilityConfigs) do
        table.insert(list, {
            id = id,
            name = cfg.name or id, -- Fallback to ID if name not in config
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
    guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_pay", label = "Total pay: $" .. sessionTotalPay, type = "message", clear = false })
    guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_rep", label = "Total rep: " .. sessionTotalRep, type = "message", clear = false })
    notifyPhoneState()
end

local function spawnBatch(facilityId)
    if not loadConfig() then return false end
    local facCfg = facilityConfigs[facilityId]
    if not facCfg then return false end

    local vertices = getSpawnZoneVertices(facCfg.spawnZone)
    if not vertices then return false end

    -- Use facility's "triggers" list from JSON, or fall back to global DROP_TRIGGER_NAMES
    local triggerNames = (facCfg.triggers and #facCfg.triggers > 0) and facCfg.triggers or DROP_TRIGGER_NAMES
    local resolved = resolveDropTriggers(triggerNames)
    local dropList = {}
    for n in pairs(resolved) do table.insert(dropList, n) end
    if #dropList == 0 then return false end
    local dropName = dropList[math.random(1, #dropList)]
    local dropTrigger = resolved[dropName]
    if not dropTrigger then return false end

    -- One material per batch: pick one from spawns, spawn batchSize of it.
    local spawns = facCfg.spawns or {}
    if #spawns == 0 then return false end
    
    -- Use player preference if set, otherwise config default, otherwise 8
    local baseSize = tonumber(facCfg.batchSize) or 8
    local batchSize = preferredBatchSize or baseSize
    batchSize = math.max(1, batchSize) -- Minimum 1
    
    local spawnDef = spawns[math.random(1, #spawns)]
    local mat = materialsById[spawnDef.materialId]
    if not mat or not mat.model_key or not mat.config then return false end

    local propIds = {}
    local moneyPerProp = {}
    local repPerProp = {}
    local spacing = mat.spawnGridSpacing or 2
    local positions = computeSpawnPositionsInZone(vertices, batchSize, spacing)
    local numToSpawn = batchSize -- Force spawn requested amount (computeSpawnPositionsInZone now handles this)
    
    if numToSpawn == 0 then return false end
    -- Spawn rotation Z (degrees) from facility config; default 0
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
        end
    end

    if #propIds == 0 then return false end

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
    currentBatch = nil
end

-- Clear AI truck state and despawn truck + reserved load props (no path references; vehicle from config).
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
    truckState = nil
    truckRoadNodes = nil
    truckTargetNodeIndex = nil
    truckMaterialName = nil
    truckFacilityId = nil
end

-- Spawn truck at facilityWork_truckSpawn, drive to pickup node (e.g. node 18). Config: facCfg.truck (model/config), facCfg.aiPickupRoadName, facCfg.aiPickupNodeIndex (1-based), facCfg.truckSpawnSpot.
local function spawnTruckAndDriveToPickup(facilityId)
    if truckState then return false end
    if not loadConfig() then return false end
    local facCfg = facilityConfigs[facilityId]
    if not facCfg then return false end
    local roadName = facCfg.aiPickupRoadName or "industrialWarehouse_aiPickup"
    local nodes = getRoadNodes(roadName)
    if not nodes or #nodes == 0 then return false end
    -- aiPickupNodeIndex in config is 1-based (node 18); convert to 0-based
    local pickupIndex1 = tonumber(facCfg.aiPickupNodeIndex) or 18
    local pickupIndex0 = math.max(0, math.min(pickupIndex1 - 1, #nodes - 1))
    local spotName = facCfg.truckSpawnSpot or TRUCK_SPAWN_SPOT_NAME
    local spawnData = getForkliftSpawnPoint(spotName)
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
    truckState = "driving_to_pickup"
    truckRoadNodes = nodes
    truckTargetNodeIndex = pickupIndex0
    truckFacilityId = facilityId
    -- Path from first road node to pickup node (script teleports truck to first node then drives)
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
    return true
end

-- Complete batch (all props in drop zone): accumulate money/rep into session totals, despawn batch, spawn next.
-- No payment or save here; payout and save happen once on end shift.
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
    local mult = 1
    if career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
        mult = career_economyAdjuster.getSectionMultiplier("facilityWork") or 1
    end
    totalMoney = math.floor(totalMoney * mult)
    sessionTotalPay = sessionTotalPay + totalMoney
    sessionTotalRep = sessionTotalRep + totalRep
    sessionMaterialsMoved = sessionMaterialsMoved + #propIds

    -- Persistent materials: keep delivered props in world until shift ends
    for _, pid in ipairs(propIds) do
        table.insert(sessionDeliveredVehicles, pid)
    end
    -- Performance cap: remove oldest props if over limit
    while #sessionDeliveredVehicles > MAX_PERSISTENT_PROPS do
        local pid = table.remove(sessionDeliveredVehicles, 1)
        local obj = be:getObjectByID(pid)
        if obj then obj:delete() end
    end

    table.clear(propsInDropZone)
    currentBatch = nil
    updateTasklistValues()

    if facilityId and spawnBatch(facilityId) then
        if currentBatch and currentBatch.dropTrigger then
            showDropMarkers(currentBatch.dropTrigger)
        end
    end
end

-- End Shift: despawn forklift, props, session materials, markers, truck, etc.
local function endShiftCleanup()
    if currentBatch then
        for _, pid in ipairs(currentBatch.propIds) do
            local obj = be:getObjectByID(pid)
            if obj then obj:delete() end
        end
        currentBatch = nil
    end
    -- Remove all persistent (delivered) materials from the session
    for _, pid in ipairs(sessionDeliveredVehicles) do
        local obj = be:getObjectByID(pid)
        if obj then obj:delete() end
    end
    -- Despawn the facility forklift if we're tracking one
    if currentForkliftId then
        local obj = be:getObjectByID(currentForkliftId)
        if obj then obj:delete() end
        currentForkliftId = nil
    end
    clearTruckState()
    truckNextSpawnTime = nil

    table.clear(sessionDeliveredVehicles)
    table.clear(propsInDropZone)
    clearDropMarkers()
    batchReadyWaitingForkliftExit = false

    -- Single payout and save at end of shift (avoids log spam and ensures reward is applied once)
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

    -- Show shift summary before clearing UI
    if utils and utils.displayMessage then
        local msg = string.format("Shift ended. Total earned: $%d | Rep: %d | Materials moved: %d",
            sessionTotalPay, sessionTotalRep, sessionMaterialsMoved)
        utils.displayMessage(msg, 6)
    end

    sessionTotalPay = 0
    sessionTotalRep = 0
    sessionMaterialsMoved = 0

    guihooks.trigger('ClearTasklist')
    notifyPhoneState()
    if utils and utils.restoreTrafficAmount then
        utils.restoreTrafficAmount()
    end
end

local function doStartFacilityWork()
    if not career_career or not career_career.isActive() then return false end
    if not loadConfig() then
        if utils and utils.displayMessage then
            utils.displayMessage("Facility work: config not loaded (wrong level or missing facilityWorkMaterials.json).", 5)
        end
        return false
    end
    local facilityId = selectedFacilityId
    
    -- If no valid selection, pick the first available facility
    if not facilityId or not facilityConfigs[facilityId] then
        facilityId = next(facilityConfigs)
    end
    if not facilityId then
        if utils and utils.displayMessage then
            utils.displayMessage("Facility work: no facility config found.", 5)
        end
        return false
    end
    local facCfg = facilityConfigs[facilityId]
    local vertices = getSpawnZoneVertices(facCfg.spawnZone)
    if not vertices or #vertices < 3 then
        if utils and utils.displayMessage then
            local zName = facCfg.spawnZone or "facilityWork_spawnZone"
            utils.displayMessage("Facility work: spawn zone '"..zName.."' not found in roleplay.sites.json.", 8)
        end
        return false
    end
    local triggerNames = (facCfg.triggers and #facCfg.triggers > 0) and facCfg.triggers or DROP_TRIGGER_NAMES
    local resolved = resolveDropTriggers(triggerNames)
    local dropList = {}
    for n in pairs(resolved) do table.insert(dropList, n) end
    if #dropList == 0 then
        if utils and utils.displayMessage then
            utils.displayMessage("Facility work: no drop trigger found. Add trigger names under \"triggers\" in facilityWorkMaterials.json for this facility, or place a BeamNGTrigger named 'facilityWork_drop' with luaFunction onBeamNGTrigger.", 8)
        end
        return false
    end
    if currentBatch then
        despawnBatch()
    end
    -- New shift: clear any previous session's delivered materials (clean slate)
    for _, pid in ipairs(sessionDeliveredVehicles) do
        local obj = be:getObjectByID(pid)
        if obj then obj:delete() end
    end
    table.clear(sessionDeliveredVehicles)
    table.clear(propsInDropZone)
    batchReadyWaitingForkliftExit = false
    if not spawnBatch(facilityId) then
        if utils and utils.displayMessage then
            utils.displayMessage("Facility work: could not spawn batch (check spawn zone and drop trigger).", 5)
        end
        return false
    end
    -- Use current player vehicle as forklift if in one; else set when they enter a vehicle (onVehicleSwitched)
    -- currentForkliftId = be:getPlayerVehicleID(0)
    
    -- Spawn facility vehicle (forklift) at designated spot
    local spawnData = getForkliftSpawnPoint(facCfg.parkingSpot)
    if not spawnData then
        if utils and utils.displayMessage then
            local sName = facCfg.parkingSpot or "facilityWork_vehicle"
            utils.displayMessage("Facility work error: '"..sName.."' parking spot not found in roleplay.sites.json.", 6)
        end
        -- Fallback? No, user requested fail if not found/strict spawn. But we can abort.
        -- Clean up the batch we just spawned since we can't work without a forklift
        despawnBatch()
        return false
    end

    -- Get vehicle config from facility config or default
    local vehInfo = facCfg.vehicle or {}
    local model = vehInfo.model or "forklift"
    local config = vehInfo.config or "standard"
    -- Optional: color, etc.

    local vehObj = core_vehicles.spawnNewVehicle(model, {
        pos = spawnData.pos,
        rot = spawnData.rot,
        config = config,
        autoEnterVehicle = false -- let player walk to it
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
    setTasklistOnDuty()
    updateTasklistValues()
    if currentBatch and currentBatch.dropTrigger then
        showDropMarkers(currentBatch.dropTrigger)
    end
    if utils and utils.displayMessage then
        utils.displayMessage("On duty. Use the company forklift to move materials.", 4)
    end
    -- Spawn AI truck at facilityWork_truckSpawn if this facility has truck/road config (e.g. industrialWarehouse)
    if facCfg.aiPickupRoadName and getRoadNodes(facCfg.aiPickupRoadName) and #(getRoadNodes(facCfg.aiPickupRoadName) or {}) > 0 then
        spawnTruckAndDriveToPickup(facilityId)
    end
    return true
end

-- Drop trigger only (no start trigger); facility work is started from the phone.
local function onBeamNGTrigger(data)
    if not career_career or not career_career.isActive() then return end
    local triggerName = data.triggerName
    local event = data.event

    -- Drop zone: when a prop enters, mark it; when ALL batch props are in zone, wait for forklift to leave before paying out.
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
    if not career_career or not career_career.isActive() then return end
    
    -- DISABLED: Do not end shift on vehicle exit. Player must use phone to end shift.
    -- if currentForkliftId and _oldId == currentForkliftId then
    --    onForkliftExit()
    --    return
    -- end

    -- Started from phone without a vehicle: if we somehow don't have a forklift ID yet (fallback), capture it.
    -- But now we spawn it, so this shouldn't be needed usually.
    if currentBatch and not currentForkliftId and newId then
        currentForkliftId = newId
    end
end

local function onExtensionLoaded()
    configLoaded = false
    configLoadedForLevel = nil
end

local function onExtensionUnloaded()
    if currentBatch then despawnBatch() end
    for _, pid in ipairs(sessionDeliveredVehicles) do
        local obj = be:getObjectByID(pid)
        if obj then obj:delete() end
    end
    if currentForkliftId then
        local obj = be:getObjectByID(currentForkliftId)
        if obj then obj:delete() end
        currentForkliftId = nil
    end
    clearTruckState()

    table.clear(sessionDeliveredVehicles)
    table.clear(propsInDropZone)
    batchReadyWaitingForkliftExit = false
    clearDropMarkers()
    dropTriggersByName = {}
    if utils and utils.restoreTrafficAmount then
        utils.restoreTrafficAmount()
    end
    guihooks.trigger('ClearTasklist')
end

-- Update truck AI: check arrival at pickup node or at end node, then stop or despawn. Also spawn next truck when interval timer fires.
local function onUpdate(dtReal, dtSim, dtRaw)
    if not career_career or not career_career.isActive() then return end
    -- On duty with no truck and interval timer expired: spawn next truck (every 5 min real time)
    if currentForkliftId and not truckState and truckNextSpawnTime and os.clock() >= truckNextSpawnTime then
        truckNextSpawnTime = nil
        local facilityId = selectedFacilityId
        if facilityId and facilityConfigs[facilityId] then
            local facCfg = facilityConfigs[facilityId]
            if facCfg.aiPickupRoadName and getRoadNodes(facCfg.aiPickupRoadName) and #(getRoadNodes(facCfg.aiPickupRoadName) or {}) > 0 then
                spawnTruckAndDriveToPickup(facilityId)
                if utils and utils.displayMessage then
                    utils.displayMessage("Next truck arriving.", 3)
                end
            end
        end
    end
    if not truckState or not truckRoadNodes or not truckVehicleId then return end
    local vehObj = be:getObjectByID(truckVehicleId)
    if not vehObj then
        clearTruckState()
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
            truckState = "waiting_for_load"
            -- Reserve 4 props from current batch for this truck (remove from batch so they won't be paid on drop)
            local materialName = "materials"
            if currentBatch and #currentBatch.propIds >= 1 then
                materialName = currentBatch.materialName or materialName
                local nTake = math.min(TRUCK_LOAD_COUNT, #currentBatch.propIds)
                for i = 1, nTake do
                    table.insert(truckLoadPropIds, currentBatch.propIds[i])
                end
                -- Remove first nTake from batch (rebuild arrays)
                local newPropIds, newMoney, newRep = {}, {}, {}
                for i = nTake + 1, #currentBatch.propIds do
                    table.insert(newPropIds, currentBatch.propIds[i])
                    table.insert(newMoney, currentBatch.moneyPerProp[i])
                    table.insert(newRep, currentBatch.repPerProp[i])
                end
                currentBatch.propIds = newPropIds
                currentBatch.moneyPerProp = newMoney
                currentBatch.repPerProp = newRep
            end
            truckMaterialName = materialName
            -- Set navigation to truck position
            if core_groundMarkers and core_groundMarkers.setPath then
                core_groundMarkers.setPath(pos, { clearPathOnReachingTarget = false })
            end
            if utils and utils.displayMessage then
                utils.displayMessage("Load 4 of " .. materialName .. " onto the truck. Navigation set to truck. When done, tap Complete loading in Facility Work.", 8)
            end
            notifyPhoneState()
        end
    elseif truckState == "driving_to_end" then
        if dist < TRUCK_ARRIVAL_RADIUS_M then
            -- Bonus pay for completing truck loading
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
            notifyPhoneState()
        end
    end
end

function M.requestFacilityWorkState()
    notifyPhoneState()
end

function M.startFacilityWork()
    return doStartFacilityWork()
end

function M.selectFacility(id)
    if facilityConfigs[id] then
        selectedFacilityId = id
        notifyPhoneState()
    end
end

function M.setBatchSize(size)
    local s = tonumber(size)
    if s and s >= 1 then
        preferredBatchSize = math.floor(s)
        notifyPhoneState()
    end
end

function M.endFacilityWork()
    -- Explicit end shift from phone
    endShiftCleanup()
end

-- Called from phone when player taps "Complete loading": truck drives to last node then despawns with reserved materials.
function M.completeTruckLoading()
    if truckState ~= "waiting_for_load" or not truckRoadNodes or #truckRoadNodes == 0 or not truckVehicleId then return end
    local vehObj = be:getObjectByID(truckVehicleId)
    if not vehObj then
        clearTruckState()
        notifyPhoneState()
        return
    end
    -- Path from current (pickup) node to last node. truckTargetNodeIndex is 0-based pickup index.
    local fromIdx = truckTargetNodeIndex + 1  -- 1-based
    local toIdx = #truckRoadNodes
    local scriptToEnd = buildScriptPath(truckRoadNodes, fromIdx, toIdx)
    truckTargetNodeIndex = toIdx - 1  -- 0-based last index for arrival check
    truckState = "driving_to_end"
    if scriptToEnd then
        sendTruckDriveScript(vehObj, scriptToEnd)
    end
    if core_groundMarkers and core_groundMarkers.setPath then
        core_groundMarkers.setPath(nil)
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
