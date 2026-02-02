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

local ZONE_LENIENCY_M = 3
local PARTIAL_CREDIT_FACTOR = 0.5

-- Trigger naming (level editor; no start trigger - started from phone)
local DROP_TRIGGER_PREFIX = "facilityWork_drop"
local SPAWN_ZONE_NAME = "facilityWork_spawnZone"
-- Explicit drop trigger names (add more if you place additional drop zones)
local DROP_TRIGGER_NAMES = { "facilityWork_drop" }

-- Config (loaded from current level; invalidated when level changes)
local materialsById = {}
local facilityConfigs = {}
local configLoaded = false
local configLoadedForLevel = nil

-- Session state (persistent across batches in one "on duty" period)
local sessionTotalPay = 0
local sessionTotalRep = 0
local sessionMaterialsMoved = 0

-- Current batch
local currentForkliftId = nil
local currentBatch = nil  -- { facilityId, dropTrigger, propIds = {}, moneyPerProp = {}, organizationId, repPerProp }

-- Props that have entered the drop zone this batch (all must be in before we credit/despawn)
local propsInDropZone = {}

-- All items in zone; wait for forklift to exit drop zone before paying out (so player "puts down" and leaves the bay)
local batchReadyWaitingForkliftExit = false

-- Drop triggers cache (name -> scenetree ref)
local dropTriggersByName = {}

-- Drop-zone corner markers (bus.lua-style)
local dropMarkerObjects = {}

local function loadConfig()
    local levelId = getCurrentLevelIdentifier()
    if not levelId then return false end
    if configLoaded and configLoadedForLevel == levelId then return true end
    configLoaded = false
    configLoadedForLevel = nil
    local levelInfo = core_levels.getLevelByName(levelId)
    if not levelInfo or not levelInfo.dir then return false end
    local path = levelInfo.dir .. "/facilityWorkMaterials.json"
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

-- Get zone vertices from level sites (roleplay.sites.json). Use game's path resolution so mod level is found.
local function getSpawnZoneVertices()
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
        if name == SPAWN_ZONE_NAME and z.vertices and #z.vertices >= 3 then
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
-- spacing: grid step; stackHeight: optional Z offset per stack layer; stackLayers: 1 = no stacking.
local function computeSpawnPositionsInZone(vertexList, count, spacing, stackHeight, stackLayers)
    spacing = spacing or 2
    stackLayers = math.max(1, tonumber(stackLayers) or 1)
    stackHeight = tonumber(stackHeight) or 0
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
    for i = 1, math.min(count, #candidates) do
        local c = candidates[i]
        local layer = (i - 1) % stackLayers
        local zOff = layer * stackHeight
        table.insert(positions, vec3(c.x, c.y, baseZ + zOff))
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

-- Legacy: fill global dropTriggersByName from DROP_TRIGGER_NAMES (used when no facCfg.triggers)
local function collectDropTriggers()
    dropTriggersByName = {}
    for _, name in ipairs(DROP_TRIGGER_NAMES) do
        local obj = scenetree.findObject(name)
        if obj and obj.getId then
            dropTriggersByName[name] = obj
        end
    end
    return dropTriggersByName
end

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
    if not rot then return quat(1, 0, 0, 0) end
    if type(rot) == "table" then
        local x = rot.x or rot[1] or 1
        local y = rot.y or rot[2] or 0
        local z = rot.z or rot[3] or 0
        local w = rot.w or rot[4] or 0
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

-- Zone band: "full", "partial", "none"
local function getPropZoneBand(propPos, dropTrigger)
    if isPointInsideTriggerBox(propPos, dropTrigger) then
        return "full"
    end
    local dist = distanceToTriggerBox(propPos, dropTrigger)
    if dist <= ZONE_LENIENCY_M then
        return "partial"
    end
    return "none"
end

local function setTasklistOnDuty()
    guihooks.trigger('SetTasklistHeader', { label = "On duty" })
    guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_pay", label = "Total pay: $0", type = "message", clear = false })
    guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_rep", label = "Total rep: 0", type = "message", clear = false })
    guihooks.trigger('SetTasklistTask', { id = "facilityWork_materials", label = "Materials moved: 0", type = "message", clear = false })
end

-- Phone app: build state for UI (onDuty, session stats, available on this level)
local function isFacilityWorkAvailable()
    if not loadConfig() then return false end
    local verts = getSpawnZoneVertices()
    if not verts or #verts < 3 then return false end
    local facilityId = nil
    for fid in pairs(facilityConfigs) do facilityId = fid break end
    if not facilityId then return false end
    local facCfg = facilityConfigs[facilityId]
    local triggerNames = (facCfg.triggers and #facCfg.triggers > 0) and facCfg.triggers or DROP_TRIGGER_NAMES
    local resolved = resolveDropTriggers(triggerNames)
    for _ in pairs(resolved) do return true end
    return false
end

local function getFacilityWorkState()
    return {
        onDuty = (currentBatch ~= nil or currentForkliftId ~= nil),
        sessionTotalPay = sessionTotalPay,
        sessionTotalRep = sessionTotalRep,
        sessionMaterialsMoved = sessionMaterialsMoved,
        available = isFacilityWorkAvailable()
    }
end

local function notifyPhoneState()
    guihooks.trigger('updateFacilityWorkState', getFacilityWorkState())
end

local function updateTasklistValues()
    guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_pay", label = "Total pay: $" .. sessionTotalPay, type = "message", clear = false })
    guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_rep", label = "Total rep: " .. sessionTotalRep, type = "message", clear = false })
    guihooks.trigger('SetTasklistTask', { id = "facilityWork_materials", label = "Materials moved: " .. sessionMaterialsMoved, type = "message", clear = false })
    notifyPhoneState()
end

local function spawnBatch(facilityId)
    if not loadConfig() then return false end
    local facCfg = facilityConfigs[facilityId]
    if not facCfg then return false end

    local vertices = getSpawnZoneVertices()
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
    local batchSize = math.max(1, tonumber(facCfg.batchSize) or 8)
    local spawnDef = spawns[math.random(1, #spawns)]
    local mat = materialsById[spawnDef.materialId]
    if not mat or not mat.model_key or not mat.config then return false end

    local propIds = {}
    local moneyPerProp = {}
    local repPerProp = {}
    local spacing = mat.spawnGridSpacing or 2
    local stackHeight = mat.stackHeight or facCfg.stackHeight or 0
    local stackLayers = tonumber(facCfg.stackLayers) or tonumber(mat.stackLayers) or 1
    local positions = computeSpawnPositionsInZone(vertices, batchSize, spacing, stackHeight, stackLayers)
    local numToSpawn = math.min(batchSize, #positions)
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
        organizationId = facCfg.organizationId
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

-- Pay out entire batch (all props were in drop zone): sum money/rep, reward once, despawn all, spawn new batch.
local function payoutBatchAndSpawnNext()
    if not currentBatch then return end
    local propIds = currentBatch.propIds
    local moneyPerProp = currentBatch.moneyPerProp
    local repPerProp = currentBatch.repPerProp
    local organizationId = currentBatch.organizationId
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

    if career_career and career_career.isActive() and career_modules_payment and career_modules_payment.reward and (totalMoney ~= 0 or totalRep ~= 0) then
        local rewardData = {
            money = { amount = totalMoney },
            beamXP = { amount = math.floor(totalMoney / 10) }
        }
        rewardData[organizationId .. "Reputation"] = { amount = totalRep }
        career_modules_payment.reward(rewardData, {
            label = string.format("Facility work: $%d | Rep +%d | %d materials", totalMoney, totalRep, #propIds),
            tags = {"facilityWork", "gameplay"}
        }, true)
    end
    if career_saveSystem and career_saveSystem.saveCurrent then
        career_saveSystem.saveCurrent()
    end

    for _, pid in ipairs(propIds) do
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

-- Exit forklift: despawn remaining props, clear markers, show total earned, save, clear UI.
local function onForkliftExit()
    if currentBatch then
        for _, pid in ipairs(currentBatch.propIds) do
            local obj = be:getObjectByID(pid)
            if obj then obj:delete() end
        end
        currentBatch = nil
    end
    table.clear(propsInDropZone)
    clearDropMarkers()
    batchReadyWaitingForkliftExit = false

    -- Show shift summary and save before clearing UI
    if utils and utils.displayMessage then
        local msg = string.format("Shift ended. Total earned: $%d | Rep: %d | Materials moved: %d",
            sessionTotalPay, sessionTotalRep, sessionMaterialsMoved)
        utils.displayMessage(msg, 6)
    end
    if career_saveSystem and career_saveSystem.saveCurrent then
        career_saveSystem.saveCurrent()
    end

    guihooks.trigger('ClearTasklist')
    currentForkliftId = nil
    notifyPhoneState()
    if utils and utils.restoreTrafficAmount then
        utils.restoreTrafficAmount()
    end
end

-- Start facility work from phone (no start trigger). Sets currentForkliftId to player vehicle if in one, else when they enter a vehicle.
local function doStartFacilityWork()
    if not career_career or not career_career.isActive() then return false end
    if not loadConfig() then
        if utils and utils.displayMessage then
            utils.displayMessage("Facility work: config not loaded (wrong level or missing facilityWorkMaterials.json).", 5)
        end
        return false
    end
    local facilityId = nil
    for fid in pairs(facilityConfigs) do
        facilityId = fid
        break
    end
    if not facilityId then
        if utils and utils.displayMessage then
            utils.displayMessage("Facility work: no facility config found.", 5)
        end
        return false
    end
    local facCfg = facilityConfigs[facilityId]
    local vertices = getSpawnZoneVertices()
    if not vertices or #vertices < 3 then
        if utils and utils.displayMessage then
            utils.displayMessage("Facility work: spawn zone not found. In roleplay.sites.json (facilities/delivery) add a zone named 'facilityWork_spawnZone' with at least 3 vertices.", 8)
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
    table.clear(propsInDropZone)
    batchReadyWaitingForkliftExit = false
    if not spawnBatch(facilityId) then
        if utils and utils.displayMessage then
            utils.displayMessage("Facility work: could not spawn batch (check spawn zone and drop trigger).", 5)
        end
        return false
    end
    -- Use current player vehicle as forklift if in one; else set when they enter a vehicle (onVehicleSwitched)
    currentForkliftId = be:getPlayerVehicleID(0)
    if utils and utils.saveAndSetTrafficAmount then
        utils.saveAndSetTrafficAmount(0)
    end
    setTasklistOnDuty()
    updateTasklistValues()
    if currentBatch and currentBatch.dropTrigger then
        showDropMarkers(currentBatch.dropTrigger)
    end
    if utils and utils.displayMessage then
        utils.displayMessage("On duty. Move materials to the drop zone.", 4)
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

local function onVehicleSwitched(oldId, newId)
    if not career_career or not career_career.isActive() then return end
    if currentForkliftId and oldId == currentForkliftId then
        onForkliftExit()
        return
    end
    -- Started from phone without a vehicle: when player enters any vehicle, treat it as the forklift
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
    table.clear(propsInDropZone)
    batchReadyWaitingForkliftExit = false
    clearDropMarkers()
    currentForkliftId = nil
    dropTriggersByName = {}
    if utils and utils.restoreTrafficAmount then
        utils.restoreTrafficAmount()
    end
    guihooks.trigger('ClearTasklist')
end

function M.requestFacilityWorkState()
    notifyPhoneState()
end

function M.startFacilityWork()
    return doStartFacilityWork()
end

function M.endFacilityWork()
    if currentBatch or currentForkliftId then
        onForkliftExit()
    end
end

M.onBeamNGTrigger = onBeamNGTrigger
M.onVehicleSwitched = onVehicleSwitched
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
