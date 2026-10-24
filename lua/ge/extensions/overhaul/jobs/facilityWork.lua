-- Facility loading batches, forklift work, truck arrivals and shift rewards.
-- Read config, session state, parts, batch operations, truck updates, public actions and hooks.
local recordShift = require("overhaul/lib/progression/logbookFeed").register("overhaul.facilityShiftCompleted", {
  title = "Facility shift completed", label = "Employment", icon = "wrench"
}, "jobs/facilityWork.lua")

local M = {}
M.dependencies = {'overhaul_phone_phone', 'overhaul_events_utils'}

local core_vehicles = require('core/vehicles')
local core_groundMarkers = require('core/groundMarkers')

-- Config ------------------------------------------------------------------------------------------

local MAX_PERSISTENT_PROPS = 50
local TRUCK_ARRIVAL_RADIUS_M = 10
local TRUCK_LOAD_COUNT = 4
local TRUCK_LOADING_BONUS_DEFAULT = 2500
local TRUCK_SPAWN_INTERVAL_REAL_SEC = 300
local FORKLIFT_REPAIR_PENALTY = 500
local BATCH_LOAD_ARRIVAL_RADIUS_M = 12
local TRUCK_PICKUP_ARRIVAL_RADIUS_M = 12
local TRUCK_BED_LOAD_RADIUS_M = 8  -- semi flatbed extends far behind cab; adjust if too lenient
local TRUCK_FORKLIFT_OPEN_PHONE_RADIUS_M = 15  -- open phone / show message only when forklift is at least this far from truck

-- State -------------------------------------------------------------------------------------------

local materialsById = {}
local facilityConfigs = {}
local configLoaded = false
local configLoadedForLevel = nil

local sessionTotalPay = 0
local sessionTotalRep = 0
local sessionMaterialsMoved = 0
local sessionMultiplier = 1  -- increases per batch (configurable per facility); applied to batch pay
local selectedFacilityId = nil
local preferredBatchSize = nil
local deliveredPropsByZone = {}
local pendingBatchFacilityId = nil

local currentForkliftId = nil
local currentBatch = nil

local propsInDropZone = {}

local truckVehicleId = nil
local truckNextSpawnTime = nil
local truckState = nil
local truckRoadNodes = nil
local truckTargetNodeIndex = nil
local truckArrivedAtNodeIndex = nil  -- node index where truck stopped for loading (used for drive-to-end path)
local truckLoadPropIds = {}
local truckFacilityId = nil
local truckLoadingDropTrigger = nil
local propsEligibleForTruckLoad = {}  -- pid -> true, props in zone that can be loaded (from deliveredPropsByZone)
local truckLoadMaterialName = nil  -- material name for UI message, e.g. "TastiCola"
local truckLoadTargetCount = nil   -- number to load (for tasklist), e.g. 4
local truckLoadPropPay = {}        -- pid -> base pay (for 1.5x loading bonus, same as batch pay per prop)
local selectedZoneNameForTruckLoad = nil  -- zone picked at dispatch so we show "Load N X" before truck arrives
local truckFullyLoadedNotified = false    -- one-shot: notify phone when truck load reaches target
local truckFullForkliftWasNear = false     -- true once forklift has been within 5m of truck while truck was full (avoids opening when prop alone was in range)

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

local parts = {}

-- Facility config ---------------------------------------------------------------------------------

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
  local path = levelInfo.dir .. "/overhaul/facilityWork.json"
  local data = jsonReadFile(path)
  if not data or not data.materials then log("W", "facilityWork", "Facility work disabled: missing " .. path); return false end
  materialsById = data.materials
  facilityConfigs = {}
  parts.sites.set_facilityConfigs(facilityConfigs)
  parts.markers.set_facilityConfigs(facilityConfigs)
  for k, v in pairs(data) do
    if k ~= "materials" and type(v) == "table" and v.organizationId and v.spawns and v.sitesFile and v.triggers then
      facilityConfigs[k] = v
    elseif k ~= "materials" and k ~= "version" then
      log("W", "facilityWork", "Facility disabled: missing organizationId/spawns/sitesFile/triggers for " .. k)
    end
  end
  configLoaded = true
  configLoadedForLevel = levelId
  return true
end

-- Parts -------------------------------------------------------------------------------------------

parts.geometry = require('overhaul/jobs/facilityWork/geometry')()
parts.sites = require('overhaul/jobs/facilityWork/sites')(facilityConfigs,
  parts.geometry.getZoneCenter, loadConfig, parts.geometry.toVec3, parts.geometry.validZoneVertices)

local function getForkliftPosition()
  if not currentForkliftId then return nil end
  local obj = be:getObjectByID(currentForkliftId)
  if not obj or not obj.getPosition then return nil end
  return parts.geometry.toVec3(obj:getPosition())
end

local function isForkliftInLoadZone(facilityId)
  local position = getForkliftPosition()
  if not position then return false end
  local facilityConfig = facilityId and facilityConfigs[facilityId]
  if not facilityConfig then return false end
  local names = parts.sites.getFacilitySpawnZoneNames(facilityConfig)
  for _, name in ipairs(names) do
    local zoneVertices = parts.sites.getSpawnZoneVertices(name, facilityConfig)
    if zoneVertices and parts.geometry.isPointInPolygon2D(position.x, position.y, zoneVertices) then return true end
  end
  return false
end

parts.truckDrive = require('overhaul/jobs/facilityWork/truckDrive')(core_groundMarkers, parts.geometry.toVec3)

parts.markers = require('overhaul/jobs/facilityWork/markers')(dropMarkerObjects,
  facilityConfigs, parts.sites.getFacilitySpawnZoneNames, parts.sites.getForkliftSpawnPoint, parts.sites.getSpawnZoneVertices,
  loadConfig, loadZoneMarkerObjects, parts.truckDrive.setNavigationPath, parts.geometry.toVec3)

-- Guidance and phone state ------------------------------------------------------------------------

local function refreshGuidanceMarkers()
  parts.markers.clearDropMarkers()
  if currentBatch then
    parts.markers.showLoadZoneMarkers(currentBatch.facilityId, { clear = true, color = "0.23 0.72 1.00 1", prefix = "loadingMarker", markerList = loadZoneMarkerObjects })
    if currentBatch.dropTrigger then
      parts.markers.showDropMarkers(currentBatch.dropTrigger, { clear = false, color = "0.6 0.9 0.23 1", prefix = "deliveryMarker", markerList = dropMarkerObjects, label = "delivery marker" })
    end
  end
  if truckState == "waiting_for_load" then
    if truckLoadingDropTrigger then
      parts.markers.showDropMarkers(truckLoadingDropTrigger, { clear = false, color = "1.00 0.80 0.16 1", prefix = "truckPickupMarker", markerList = dropMarkerObjects, label = "truck pickup marker" })
    end
  end
end

local function getSessionMultiplierHeaderLabel()
  local rewardMultiplier = sessionMultiplier
  local multiplierText
  if rewardMultiplier == math.floor(rewardMultiplier) then
    multiplierText = tostring(rewardMultiplier)
  else
    multiplierText = string.format("%.2f", rewardMultiplier)
  end
  return "On duty: x" .. multiplierText
end

local function setTasklistOnDuty()
  guihooks.trigger('SetTasklistHeader', { label = getSessionMultiplierHeaderLabel() })
  guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_pay", label = "Total pay: $0", type = "message", clear = false })
  guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_rep", label = "Total rep: 0", type = "message", clear = false })
end

-- Reward scaling --------------------------------------------------------------------------------

local function scaleFacilityWorkMoneyAndRep(money, reputation, organizationId)
  local scaledMoney = math.max(0, math.floor(tonumber(money) or 0))
  local scaledReputation = math.floor(tonumber(reputation) or 0)
  if not (overhaul_career_economy_difficultyMode and overhaul_career_economy_difficultyMode.scalePaymentRewardData) then
    return scaledMoney, scaledReputation
  end
  local rewardData = {
    money = { amount = scaledMoney }
  }
  if organizationId and scaledReputation ~= 0 then
    rewardData[organizationId .. "Reputation"] = { amount = scaledReputation }
  end
  overhaul_career_economy_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = false})
  if organizationId and scaledReputation ~= 0 then
    scaledReputation = math.floor((rewardData[organizationId .. "Reputation"] and rewardData[organizationId .. "Reputation"].amount or scaledReputation) + 0.5)
  end
  return scaledMoney, scaledReputation
end

local function scaleFacilityWorkOperatorXp(xp)
  local scaledXp = math.max(0, math.floor(tonumber(xp) or 0))
  if scaledXp <= 0 then
    return 0
  end
  if overhaul_career_economy_difficultyMode and overhaul_career_economy_difficultyMode.scaleFlatRewards then
    local rewardData = { ["careerSkills-operator"] = scaledXp }
    overhaul_career_economy_difficultyMode.scaleFlatRewards(rewardData, {includeMoney = false})
    scaledXp = math.max(0, math.floor((tonumber(rewardData["careerSkills-operator"]) or scaledXp) + 0.5))
  end
  return scaledXp
end

local function getSessionDisplayTotals()
  return sessionTotalPay, sessionTotalRep
end

local function getFacilityWorkState()
  local displayPay, displayRep = getSessionDisplayTotals()
  local targetCount = truckLoadTargetCount or TRUCK_LOAD_COUNT
  local truckFullyLoaded = (truckState == "waiting_for_load") and (#truckLoadPropIds >= targetCount)
  return {
    onDuty = (currentBatch ~= nil or currentForkliftId ~= nil),
    sessionTotalPay = displayPay,
    sessionTotalRep = displayRep,
    sessionMaterialsMoved = sessionMaterialsMoved,
    available = parts.sites.isFacilityWorkAvailable(),
    facilities = parts.sites.getAvailableFacilities(),
    selectedFacilityId = selectedFacilityId,
    preferredBatchSize = preferredBatchSize,
    truckWaitingForLoad = (truckState == "waiting_for_load"),
    truckFullyLoaded = truckFullyLoaded
  }
end

local function notifyPhoneState()
  guihooks.trigger('updateFacilityWorkState', getFacilityWorkState())
end

local function updateTasklistValues()
  local displayPay, displayRep = getSessionDisplayTotals()
  guihooks.trigger('SetTasklistHeader', { label = getSessionMultiplierHeaderLabel() })
  guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_pay", label = "Total pay: $" .. displayPay, type = "message", clear = false })
  guihooks.trigger('SetTasklistTask', { id = "facilityWork_total_rep", label = "Total rep: " .. displayRep, type = "message", clear = false })
  guihooks.trigger('SetTasklistTask', { id = "facilityWork_next_stop", label = "", type = "message", clear = true })
  if truckState == "driving_to_pickup" or truckState == "waiting_for_load" then
    if truckLoadMaterialName and truckLoadTargetCount then
      local targetCount = truckLoadTargetCount or TRUCK_LOAD_COUNT
      local loadLabel
      if #truckLoadPropIds >= targetCount then
        loadLabel = "Truck full. Open phone to send."
        if currentBatch then
          loadLabel = "Truck full. Finish batch or open phone to send."
        end
      else
        loadLabel = string.format("Load %d %s onto the truck", truckLoadTargetCount, truckLoadMaterialName)
        if currentBatch then
          loadLabel = "Finish your current batch, then " .. loadLabel
        end
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

-- Waypoint phases ---------------------------------------------------------------------------------

local function setBatchWaypointPhase(phase, opts)
  opts = opts or {}
  if not currentBatch then
    currentBatchWaypointPhase = nil
    return
  end
  if phase == "to_loading" then
    local loadCenter = parts.sites.getFacilityLoadZoneCenter(currentBatch.facilityId)
    if loadCenter then
      currentBatchWaypointPhase = "to_loading"
      parts.truckDrive.setNavigationPath(loadCenter)
    end
  elseif phase == "to_delivery" then
    if currentBatch.dropTrigger then
      currentBatchWaypointPhase = "to_delivery"
      parts.truckDrive.setNavigationPath(currentBatch.dropTrigger:getPosition())
    end
  else
    currentBatchWaypointPhase = nil
  end
  refreshGuidanceMarkers()
  updateTasklistValues()
  if not opts.silent then
    if phase == "to_loading" then
      overhaul_events_utils.displayMessage("Waypoint updated: go to loading area first.", 3)
    elseif phase == "to_delivery" then
      overhaul_events_utils.displayMessage("Waypoint updated: deliver to the drop area.", 3)
    end
  end
end

local function setTruckWaypointPhase(phase, opts)
  opts = opts or {}
  if phase == "to_pickup" then
    if truckLoadingDropTrigger then
      truckWaypointPhase = "to_pickup"
      parts.truckDrive.setNavigationPath(truckLoadingDropTrigger:getPosition())
    end
  elseif phase == "to_truck" then
    local truckObj = truckVehicleId and be:getObjectByID(truckVehicleId) or nil
    if truckObj then
      truckWaypointPhase = "to_truck"
      parts.truckDrive.setNavigationPath(truckObj:getPosition())
    end
  else
    truckWaypointPhase = nil
  end
  refreshGuidanceMarkers()
  updateTasklistValues()
  if not opts.silent then
    if phase == "to_pickup" then
      overhaul_events_utils.displayMessage("Waypoint updated: pick up materials first.", 3)
    elseif phase == "to_truck" then
      overhaul_events_utils.displayMessage("Waypoint updated: load materials onto the truck.", 3)
    end
  end
end

-- Batches -----------------------------------------------------------------------------------------

local function pickBatchSpawnPositions(mat, zoneNames, batchSize, facCfg)
  local spacing = mat.spawnGridSpacing or 2
  local allPositions = {}
  for _, zoneName in ipairs(zoneNames) do
    local vertices = parts.sites.getSpawnZoneVertices(zoneName, facCfg)
    if vertices and #vertices >= 3 then
      local zonePositions = parts.geometry.computeSpawnPositionsInZone(vertices, batchSize, spacing)
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
  return positions
end

local function spawnBatchProps(facCfg, positions, numToSpawn, mat, propIds, moneyPerProp, repPerProp)
  local spawnRotationZDeg = tonumber(facCfg.spawnRotationZ)
  if spawnRotationZDeg == nil then spawnRotationZDeg = 0 end
  local rotZ = quatFromEuler(0, 0, math.rad(spawnRotationZDeg))
  local baseRot = quatFromDir(vec3(0, 1, 0))
  for i = 1, numToSpawn do
    local position = positions[i]
    if not position then break end
    local rot = rotZ * baseRot
    local obj = core_vehicles.spawnNewVehicle(mat.model_key, {
      pos = position,
      rot = rot,
      config = mat.config,
      autoEnterVehicle = false
    })
    if obj then
      local pid = obj:getID()
      table.insert(propIds, pid)
      table.insert(moneyPerProp, mat.money or 0)
      table.insert(repPerProp, math.floor((mat.money or 0) / 100))
      -- Delay rotation and retain the settled position so overlapping props can spread naturally.
      local applyRot = rot
      core_jobsystem.create(function(job)
        job.sleep(0.18)
        local o = be:getObjectByID(pid)
        if o then
          local currentPos = o.getPosition and parts.geometry.toVec3(o:getPosition()) or position
          if o.setPositionRotation then
            o:setPositionRotation(currentPos.x, currentPos.y, currentPos.z, applyRot.x, applyRot.y, applyRot.z, applyRot.w)
          elseif o.setPosRot then
            o:setPosRot(currentPos.x, currentPos.y, currentPos.z, applyRot.x, applyRot.y, applyRot.z, applyRot.w)
          end
        end
      end)
    end
  end
end

local function spawnBatch(facilityId)
  if not loadConfig() then return false end
  local facCfg = facilityConfigs[facilityId]
  if not facCfg then return false end
  local zoneNames = parts.sites.getFacilitySpawnZoneNames(facCfg)
  if #zoneNames == 0 then return false end
  local triggerNames = facCfg.triggers or {}
  local resolved = parts.truckDrive.resolveDropTriggers(triggerNames)
  local dropList = {}
  for n in pairs(resolved) do table.insert(dropList, n) end
  if #dropList == 0 then return false end
  local dropName = dropList[math.random(1, #dropList)]
  local dropTrigger = resolved[dropName]
  if not dropTrigger then return false end
  local spawns = facCfg.spawns or {}
  if #spawns == 0 then return false end
  local maxBatch = tonumber(facCfg.batchSize) or 8
  local batchSize = preferredBatchSize or maxBatch
  batchSize = math.max(1, math.min(batchSize, maxBatch))
  local spawnDef = spawns[math.random(1, #spawns)]
  local mat = materialsById[spawnDef.materialId]
  if not mat or not mat.model_key or not mat.config then return false end
  local propIds = {}
  local moneyPerProp = {}
  local repPerProp = {}
  local positions = pickBatchSpawnPositions(mat, zoneNames, batchSize, facCfg)
  local numToSpawn = #positions
  if numToSpawn == 0 then return false end
  spawnBatchProps(facCfg, positions, numToSpawn, mat, propIds, moneyPerProp, repPerProp)
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
  parts.markers.clearDropMarkers()
  for _, pid in ipairs(currentBatch.propIds) do
    local obj = be:getObjectByID(pid)
    if obj then
      obj:delete()
    end
  end
  currentBatchWaypointPhase = nil
  currentBatch = nil
end

-- Truck dispatch ----------------------------------------------------------------------------------

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
  table.clear(truckLoadPropPay)
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
  truckFullyLoadedNotified = false
  truckFullForkliftWasNear = false
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
  table.clear(truckLoadPropPay)
  table.clear(propsEligibleForTruckLoad)
  truckLoadingDropTrigger = nil
  truckFullyLoadedNotified = false
  truckFullForkliftWasNear = false
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
    overhaul_events_utils.displayMessage(string.format("Load %d %s onto the truck.", truckLoadTargetCount, truckLoadMaterialName), 5)
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
    parts.truckDrive.setNavigationPath(nil)
    refreshGuidanceMarkers()
    updateTasklistValues()
  end
end

local function driveSpawnedTruckToPickup(nodes, pickupIndex0)
  refreshGuidanceMarkers()
  local scriptToPickup = parts.truckDrive.buildScriptPath(nodes, 1, pickupIndex0 + 1)
  if scriptToPickup then
    core_jobsystem.create(function(job)
      job.sleep(0.5)
      local v = be:getObjectByID(truckVehicleId)
      if v and truckState == "driving_to_pickup" then
        parts.truckDrive.sendTruckDriveScript(v, scriptToPickup)
      end
    end)
  end
end

local function spawnTruckAndDriveToPickup(facilityId)
  if truckState then return false end
  if not loadConfig() then return false end
  local facCfg = facilityConfigs[facilityId]
  if not facCfg then return false end
  if not facCfg.aiPickupRoadName then return false end
  local nodes = parts.truckDrive.getRoadNodes(facCfg.aiPickupRoadName)
  if not nodes or #nodes == 0 then return false end
  local pickupIndex1 = tonumber(facCfg.aiPickupNodeIndex) or 18
  local pickupIndex0 = math.max(0, math.min(pickupIndex1 - 1, #nodes - 1))
  local driveToPickup = (facCfg.driveToPickup ~= false)
  local spawnData = parts.sites.getForkliftSpawnPoint(facCfg.truckSpawnSpot, facCfg)
  if not spawnData then
    log("W", "facilityWork", "Truck disabled: missing configured truck spawn for " .. facilityId)
    return false
  end
  local truckCfg = facCfg.truck or {}
  local model = truckCfg.model or "md_series"
  local config = truckCfg.config or "md_60_flatbed"
  local vehicleObject = core_vehicles.spawnNewVehicle(model, {
    pos = spawnData.pos,
    rot = spawnData.rot,
    config = config,
    autoEnterVehicle = false
  })
  if not vehicleObject then return false end
  truckVehicleId = vehicleObject:getID()
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
    driveSpawnedTruckToPickup(nodes, pickupIndex0)
  else
    truckState = "waiting_for_load"
    applyWaitingForLoadState()
  end
  return true
end

-- Batch payout ------------------------------------------------------------------------------------

local function retainDeliveredProps(propIds, moneyPerProp)
  if currentBatch.dropTrigger then
    local zoneName = currentBatch.dropTrigger:getName()
    local matName = currentBatch.materialName or "materials"
    if not deliveredPropsByZone[zoneName] then
      deliveredPropsByZone[zoneName] = { trigger = currentBatch.dropTrigger, propIds = {}, materialName = matName }
    end
    deliveredPropsByZone[zoneName].materialName = matName
    deliveredPropsByZone[zoneName].moneyPerPropId = deliveredPropsByZone[zoneName].moneyPerPropId or {}
    for i, pid in ipairs(propIds) do
      table.insert(deliveredPropsByZone[zoneName].propIds, pid)
      deliveredPropsByZone[zoneName].moneyPerPropId[pid] = moneyPerProp[i] or 0
    end
    lastDeliveredZoneName = zoneName
  end
  -- Future: optional LRU/oldest-zone culling when over MAX_PERSISTENT_PROPS.
  local currentTotal = getTotalDeliveredPropsCount()
  if currentTotal > MAX_PERSISTENT_PROPS then
    for zName, data in pairs(deliveredPropsByZone) do
      while #data.propIds > 0 and currentTotal > MAX_PERSISTENT_PROPS do
        local pid = table.remove(data.propIds, 1)
        if data.moneyPerPropId then data.moneyPerPropId[pid] = nil end
        local obj = be:getObjectByID(pid)
        if obj then obj:delete() end
        currentTotal = currentTotal - 1
      end
      if currentTotal <= MAX_PERSISTENT_PROPS then break end
    end
  end
end

local function prepareNextBatch(facCfg, facilityId)
  local truckSpawned = false
  local roadNodes = facCfg and facCfg.aiPickupRoadName and parts.truckDrive.getRoadNodes(facCfg.aiPickupRoadName)
  if facCfg and facCfg.aiPickupRoadName and roadNodes and #roadNodes > 0 then
    if not truckState and sessionBatchesCompleted >= firstTruckAfterBatch and getTotalDeliveredPropsCount() >= TRUCK_LOAD_COUNT then
      spawnTruckAndDriveToPickup(facilityId)
      truckSpawned = true
      -- Only apply loading zone here: batch is already cleared above, so we never overwrite current drop zone/path.
      -- (Early dispatch does not call applyWaitingForLoadState; zone/path apply when truck arrives.)
      if not currentBatch then
        applyWaitingForLoadState()
      end
      overhaul_events_utils.displayMessage("Truck arriving. Load from the marked area.", 4)
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
      parts.truckDrive.setNavigationPath(nil)
    end
  else
    if facilityId and spawnBatch(facilityId) then
      setBatchWaypointPhase("to_loading", { silent = true })
    end
  end
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
  totalMoney = math.floor(totalMoney * sessionMultiplier)
  local rewardMultiplier = overhaul_career_economyAdjuster.getSectionMultiplier("facilityWork") or 1
  totalMoney = math.floor(totalMoney * rewardMultiplier)
  totalMoney, totalRep = scaleFacilityWorkMoneyAndRep(totalMoney, totalRep, currentBatch.organizationId)
  sessionTotalPay = sessionTotalPay + totalMoney
  sessionTotalRep = sessionTotalRep + totalRep
  sessionMaterialsMoved = sessionMaterialsMoved + #propIds
  retainDeliveredProps(propIds, moneyPerProp)
  truckLoadingDropTrigger = nil
  table.clear(propsInDropZone)
  currentBatchWaypointPhase = nil
  currentBatch = nil
  parts.markers.clearDropMarkers()
  -- Increase session multiplier for next batch (per-facility config; kept low to avoid excessive earnings)
  local facCfg = facilityId and facilityConfigs[facilityId]
  local perBatch
  if facCfg then
    perBatch = tonumber(facCfg.sessionMultiplierPerBatch) or 0.15
  else
    perBatch = 0.15
  end
  sessionMultiplier = sessionMultiplier + perBatch
  updateTasklistValues()
  sessionBatchesCompleted = sessionBatchesCompleted + 1
  prepareNextBatch(facCfg, facilityId)
end

-- Shift start and end -----------------------------------------------------------------------------

local function settleShiftPay(opts)
  if overhaul_career_career and overhaul_career_career.isActive() and (sessionTotalPay ~= 0 or sessionTotalRep ~= 0) then
    local organizationId = nil
    local displayPay = sessionTotalPay
    local displayRep = sessionTotalRep
    if selectedFacilityId and facilityConfigs[selectedFacilityId] then
      organizationId = facilityConfigs[selectedFacilityId].organizationId
    end
    local skillRewards = require("overhaul/lib/jobs/skillRewards")
    local operatorLevel = skillRewards.getSkillLevel("careerSkills-operator", {"careerSkills-operator", "operator"})
    local basePay = displayPay
    displayPay = math.floor(basePay * skillRewards.getOperatorMoneyBonusMultiplier(1, operatorLevel) + 0.5)
    local surgeText = overhaul_career_economy_activityHeat.formatSurgeBonusText("facilityWork") or ""
    local accepted, problem = overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout({
      amount = displayPay,
      xp = {["careerSkills-operator"] = scaleFacilityWorkOperatorXp(math.floor(basePay / 10))},
      orgId = organizationId,
      rep = organizationId and displayRep ~= 0 and displayRep or nil,
      label = string.format("Facility work (shift): $%d%s | Rep +%d | %d materials", displayPay, surgeText, displayRep, sessionMaterialsMoved),
      tags = {"facilityWork", "gameplay"},
      fullReward = true,
    }, "activity:facilityWork", {locationId = selectedFacilityId, locationName = selectedFacilityId and facilityConfigs[selectedFacilityId] and facilityConfigs[selectedFacilityId].name, vehicleRelated = false}))
    -- A refused legacy reward still ended the shift; retain that boundary without retry.
    if accepted ~= true then log("W", "facilityWork", "Shift payout refused: " .. tostring(problem))
    else recordShift({detail = tostring(sessionMaterialsMoved) .. " materials moved", money = displayPay}) end
    if not opts.levelExit then
      overhaul_career_saveSystem.saveCurrent()
    end
    sessionTotalPay = displayPay
    sessionTotalRep = displayRep
  end
end

local function clearShiftObjects(opts)
  parts.truckDrive.setNavigationPath(nil)
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
      if not opts.levelExit and be:getPlayerVehicleID(0) == currentForkliftId then
        local position = parts.geometry.toVec3(obj:getPosition())
        if gameplay_walk and gameplay_walk.setWalkingMode then
          gameplay_walk.setWalkingMode(true, position)
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
  parts.markers.clearDropMarkers()
  batchReadyWaitingForkliftExit = false
end

local function endShiftCleanup(opts)
  opts = opts or {}
  clearShiftObjects(opts)
  if opts.discardPay then
    sessionTotalPay = 0
    sessionTotalRep = 0
  end
  settleShiftPay(opts)
  if not opts.levelExit then
    local surgeText = (overhaul_career_economy_activityHeat and overhaul_career_economy_activityHeat.formatSurgeBonusText("facilityWork")) or ""
    local msg = string.format("Shift ended. Total earned: $%d%s | Rep: %d | Materials moved: %d",
      sessionTotalPay,
      surgeText,
      sessionTotalRep,
      sessionMaterialsMoved)
    overhaul_events_utils.displayMessage(msg, 6)
  end
  sessionTotalPay = 0
  sessionTotalRep = 0
  sessionMaterialsMoved = 0
  -- Clear menu selection so a finished shift cannot appear active.
  selectedFacilityId = nil
  shiftEnded = true
  guihooks.trigger('ClearTasklist')
  notifyPhoneState()
  overhaul_events_utils.restoreTrafficAmount()
end

local function spawnShiftForklift(facCfg)
  local spawnData = parts.sites.getForkliftSpawnPoint(facCfg.forkliftSpawnSpot or facCfg.parkingSpot, facCfg)
  if not spawnData then
    local sName = facCfg.forkliftSpawnSpot or facCfg.parkingSpot or "(unconfigured)"
    overhaul_events_utils.displayMessage("Facility work error: '"..sName.."' parking spot not found in configured sites.", 6)
    despawnBatch()
    return false
  end
  local vehInfo = facCfg.vehicle or {}
  local model = vehInfo.model or "forklift"
  local config = vehInfo.config or "standard"
  local vehicleObject = core_vehicles.spawnNewVehicle(model, {
    pos = spawnData.pos,
    rot = spawnData.rot,
    config = config,
    autoEnterVehicle = false
  })
  if vehicleObject then
    currentForkliftId = vehicleObject:getID()
  else
    overhaul_events_utils.displayMessage("Facility work error: failed to spawn forklift.", 5)
    despawnBatch()
    return false
  end
end

local function validateShiftZones(facCfg)
  local zoneNames = parts.sites.getFacilitySpawnZoneNames(facCfg)
  if #zoneNames == 0 then
    overhaul_events_utils.displayMessage("Facility work: no spawn zone(s) configured.", 8)
    return false
  end
  local hasValidZone = false
  for _, zName in ipairs(zoneNames) do
    local vertices = parts.sites.getSpawnZoneVertices(zName, facCfg)
    if vertices and #vertices >= 3 then hasValidZone = true; break end
  end
  if not hasValidZone then
    overhaul_events_utils.displayMessage("Facility work: spawn zone(s) '"..table.concat(zoneNames, "', '").."' not found in configured sites.", 8)
    return false
  end
  local triggerNames = facCfg.triggers or {}
  local resolved = parts.truckDrive.resolveDropTriggers(triggerNames)
  local dropList = {}
  for n in pairs(resolved) do table.insert(dropList, n) end
  if #dropList == 0 then
    overhaul_events_utils.displayMessage("Facility work: no drop trigger found. Add trigger names under \"triggers\" in overhaul/facilityWork.json for this facility.", 8)
    return false
  end
end

local function clearPreviousBatch()
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
end

local function doStartFacilityWork()
  shiftEnded = false
  configLoaded = false
  configLoadedForLevel = nil
  if not loadConfig() then
    overhaul_events_utils.displayMessage("Facility work: config not loaded (wrong level or missing overhaul/facilityWork.json).", 5)
    return false
  end
  local facilityId = selectedFacilityId
  if not facilityId or not facilityConfigs[facilityId] then
    facilityId = next(facilityConfigs)
    selectedFacilityId = facilityId
  end
  if not facilityId then
    overhaul_events_utils.displayMessage("Facility work: no facility config found.", 5)
    return false
  end
  sessionBatchesCompleted = 0
  firstTruckAfterBatch = math.random(2, 4)
  local facCfg = facilityConfigs[facilityId]
  if validateShiftZones(facCfg) == false then return false end
  clearPreviousBatch()
  if not spawnBatch(facilityId) then
    overhaul_events_utils.displayMessage("Facility work: could not spawn batch (check spawn zone and drop trigger).", 5)
    return false
  end
  if spawnShiftForklift(facCfg) == false then return false end
  overhaul_events_utils.saveAndSetTrafficAmount(0)
  sessionMultiplier = (tonumber(facCfg.sessionMultiplierBase) or 1)
  setTasklistOnDuty()
  setBatchWaypointPhase("to_loading", { silent = true })
  overhaul_events_utils.displayMessage("On duty. Waypoint set to loading area first, then delivery. Trucks arrive after you complete a batch.", 6)
    return true
end

-- Forklift repair and trigger events --------------------------------------------------------------

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
    overhaul_events_utils.displayMessage("Forklift repair failed.", 4)
    return false
  end
  currentForkliftId = newVehObj:getID()
  newVehObj:queueLuaCommand("extensions.load('overhaulDamageState')")
  if core_vehicleBridge and core_vehicleBridge.executeAction then
    core_vehicleBridge.executeAction(newVehObj, 'initPartConditions', {}, 0, 1, 1)
  end
  be:enterVehicle(0, newVehObj)
  local penalty = FORKLIFT_REPAIR_PENALTY
  penalty = math.floor(penalty * (overhaul_career_economyAdjuster.getSectionMultiplier("facilityWork") or 1))
  sessionTotalPay = math.max(0, sessionTotalPay - penalty)
  setTasklistOnDuty()
  updateTasklistValues()
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Vehicle_Recover')
  overhaul_events_utils.displayMessage("Forklift repaired. $" .. tostring(penalty) .. " deducted from session pay.", 4)
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

local function recordBatchPropEntry(data)
  if currentBatch and currentForkliftId then
    local subjectId = data.subjectID
    for _, pid in ipairs(currentBatch.propIds) do
      if pid == subjectId then
        propsInDropZone[subjectId] = true
        local countIn = 0
        for _ in pairs(propsInDropZone) do countIn = countIn + 1 end
        if countIn >= #currentBatch.propIds then
          batchReadyWaitingForkliftExit = true
          overhaul_events_utils.displayMessage("All items delivered. Drive out of the drop zone to complete.", 4)
        end
        -- Truck spawns only on exit (in payoutBatchAndSpawnNext) to avoid stutter and props flying when spawning while still in zone
        break
      end
    end
  end
end

local function completeBatchOnForkliftExit(data)
  if currentBatch and currentForkliftId and data.subjectID == currentForkliftId and currentBatch.dropTrigger then
    local trigger = currentBatch.dropTrigger
    local countInside = 0
    for _, pid in ipairs(currentBatch.propIds) do
      local obj = be:getObjectByID(pid)
      if obj and obj.getPosition then
        local position = parts.geometry.toVec3(obj:getPosition())
        if parts.geometry.isPointInsideTriggerBox(position, trigger) then
          countInside = countInside + 1
        end
      end
    end
    if countInside >= #currentBatch.propIds then
      batchReadyWaitingForkliftExit = false
      payoutBatchAndSpawnNext()
    end
  end
end

local function onBeamNGTrigger(data)
  local triggerName = data.triggerName
  local event = data.event
  if currentBatch and currentBatch.dropTrigger and triggerName == currentBatch.dropTrigger:getName() then
    if event == "enter" then
      recordBatchPropEntry(data)
    elseif event == "exit" then
      -- Only complete when the forklift has left the zone and all props are actually inside (count on forklift exit, not prop enter)
      completeBatchOnForkliftExit(data)
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

-- Truck loading and waypoints ---------------------------------------------------------------------

local function updateWorkWaypoints()
  if currentBatch and currentBatchWaypointPhase == "to_loading" then
    local loadCenter = parts.sites.getFacilityLoadZoneCenter(currentBatch.facilityId)
    local inLoadZone = isForkliftInLoadZone(currentBatch.facilityId)
    if inLoadZone or (loadCenter and parts.geometry.isPointNear(getForkliftPosition(), loadCenter, BATCH_LOAD_ARRIVAL_RADIUS_M)) then
      setBatchWaypointPhase("to_delivery")
    end
  end
  if truckState == "waiting_for_load" and truckWaypointPhase == "to_pickup" and truckLoadingDropTrigger then
    local pickupPos = parts.geometry.toVec3(truckLoadingDropTrigger:getPosition())
    local forkliftPos = getForkliftPosition()
    local reachedPickup = forkliftPos and (parts.geometry.isPointInsideTriggerBox(forkliftPos, truckLoadingDropTrigger) or parts.geometry.isPointNear(forkliftPos, pickupPos, TRUCK_PICKUP_ARRIVAL_RADIUS_M))
    if reachedPickup then
      setTruckWaypointPhase("to_truck")
    end
  end
end

local function removeDeliveredZoneProp(zoneName, zoneData, propId)
  if not zoneData or not zoneData.propIds then return end
  for i = #zoneData.propIds, 1, -1 do
    if zoneData.propIds[i] == propId then
      table.remove(zoneData.propIds, i)
      break
    end
  end
  if #zoneData.propIds == 0 then deliveredPropsByZone[zoneName] = nil end
end

local function claimTruckLoadProps(truckPos, zoneName, zoneData, targetCount)
  for pid, _ in pairs(propsEligibleForTruckLoad) do
    if #truckLoadPropIds >= targetCount then break end
    local propObj = be:getObjectByID(pid)
    if propObj and propObj.getPosition then
      local propPos = parts.geometry.toVec3(propObj:getPosition())
      local pdx = propPos.x - truckPos.x
      local pdy = propPos.y - truckPos.y
      local pdz = propPos.z - truckPos.z
      local propDist = math.sqrt(pdx * pdx + pdy * pdy + pdz * pdz)
      if propDist < TRUCK_BED_LOAD_RADIUS_M then
        table.insert(truckLoadPropIds, pid)
        truckLoadPropPay[pid] = (zoneData and zoneData.moneyPerPropId and zoneData.moneyPerPropId[pid]) or 0
        if zoneData and zoneData.moneyPerPropId then zoneData.moneyPerPropId[pid] = nil end
        propsEligibleForTruckLoad[pid] = nil
        removeDeliveredZoneProp(zoneName, zoneData, pid)
      end
    else
      propsEligibleForTruckLoad[pid] = nil
    end
  end
end

local function notifyLoadedTruck(position, targetCount)
  if #truckLoadPropIds >= targetCount then
    local forkliftPos = getForkliftPosition()
    local truckPos = position and parts.geometry.toVec3(position) or nil
    if forkliftPos and truckPos then
      local nearTruck = parts.geometry.isPointNear(forkliftPos, truckPos, TRUCK_FORKLIFT_OPEN_PHONE_RADIUS_M)
      if nearTruck then
        truckFullForkliftWasNear = true
      end
    end
    if not truckFullyLoadedNotified and truckFullForkliftWasNear then
      local awayFromTruck = forkliftPos and truckPos and not parts.geometry.isPointNear(forkliftPos, truckPos, TRUCK_FORKLIFT_OPEN_PHONE_RADIUS_M)
      if awayFromTruck then
        truckFullyLoadedNotified = true
        updateTasklistValues()
        if overhaul_phone_phone and not overhaul_phone_phone.isPhoneOpen() then
          overhaul_phone_phone.togglePhone("Truck loaded. Open Facility Work to send it.")
        end
        overhaul_events_utils.displayMessage("Truck loaded. Open your phone to send it.", 4)
      end
    end
  end
end

local function updateWaitingTruck(position)
  local targetCount = truckLoadTargetCount or TRUCK_LOAD_COUNT
  if #truckLoadPropIds < targetCount then
    local truckPos = parts.geometry.toVec3(position)
    local zoneName = truckLoadingDropTrigger and truckLoadingDropTrigger:getName()
    local zoneData = zoneName and deliveredPropsByZone[zoneName]
    claimTruckLoadProps(truckPos, zoneName, zoneData, targetCount)
  end
  notifyLoadedTruck(position, targetCount)
end

local function finishTruckDeparture()
  local facId = truckFacilityId
  local flatBonus = TRUCK_LOADING_BONUS_DEFAULT
  if facId and facilityConfigs[facId] and facilityConfigs[facId].truckLoadingBonus then
    flatBonus = tonumber(facilityConfigs[facId].truckLoadingBonus) or flatBonus
  end
  local perPropSum = 0
  for _, pid in ipairs(truckLoadPropIds) do
    perPropSum = perPropSum + (truckLoadPropPay[pid] or 0)
  end
  local bonus = flatBonus + math.floor(perPropSum * 1.5)
  bonus = math.floor(bonus * sessionMultiplier)
  if overhaul_career_economyAdjuster then
    bonus = math.floor(bonus * (overhaul_career_economyAdjuster.getSectionMultiplier("facilityWork") or 1))
  end
  bonus = select(1, scaleFacilityWorkMoneyAndRep(bonus, 0, nil))
  sessionTotalPay = sessionTotalPay + bonus
  updateTasklistValues()
  clearTruckState()
  truckNextSpawnTime = os.clock() + TRUCK_SPAWN_INTERVAL_REAL_SEC
  overhaul_events_utils.displayMessage("Truck departed with load. Loading bonus: $" .. tostring(bonus) .. ". Next truck in 5 min.", 5)
  if pendingBatchFacilityId then
    if spawnBatch(pendingBatchFacilityId) then
      setBatchWaypointPhase("to_loading", { silent = true })
    end
    pendingBatchFacilityId = nil
  end
  notifyPhoneState()
end

-- Per-frame update --------------------------------------------------------------------------------

local function onUpdate(_dtReal, _dtSim, _dtRaw)
  updateWorkWaypoints()
  if not truckState or not truckRoadNodes or not truckVehicleId then return end
  local vehicleObject = be:getObjectByID(truckVehicleId)
  if not vehicleObject then
    clearTruckState()
    refreshGuidanceMarkers()
    notifyPhoneState()
    return
  end
  local position = vehicleObject:getPosition()
  local targetNode = truckRoadNodes[truckTargetNodeIndex + 1]
  if not targetNode then return end
  local deltaX = (targetNode.x or 0) - position.x
  local deltaY = (targetNode.y or 0) - position.y
  local deltaZ = (targetNode.z or 0) - position.z
  local distanceToTargetMeters = math.sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ)
  if truckState == "driving_to_pickup" then
    if distanceToTargetMeters < TRUCK_ARRIVAL_RADIUS_M then
      parts.truckDrive.sendTruckStop(vehicleObject)
      truckArrivedAtNodeIndex = truckTargetNodeIndex + 1  -- store node for drive-to-end path
      truckState = "waiting_for_load"
      -- Always apply: populate propsEligibleForTruckLoad, show zone markers, set path (uses pre-selected zone if still valid)
      applyWaitingForLoadState()
      updateTasklistValues()
    end
  elseif truckState == "waiting_for_load" then
    -- Position-only: any eligible prop near the truck counts as loaded (no exit event required)
    updateWaitingTruck(position)
  elseif truckState == "driving_to_end" then
    if distanceToTargetMeters < TRUCK_ARRIVAL_RADIUS_M then
      finishTruckDeparture()
    end
  end
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function onExtensionLoaded()
  configLoaded = false
  configLoadedForLevel = nil
  shiftEnded = false
  currentBatchWaypointPhase = nil
  truckWaypointPhase = nil
end

local function onExtensionUnloaded()
  if M.isFacilityWorkActive() and (sessionTotalPay ~= 0 or sessionTotalRep ~= 0) then
    local ok, err = pcall(endShiftCleanup, { levelExit = true })
    if ok then return end
    log("E", "facilityWork", "Shift payout on unload failed: " .. tostring(err))
  end
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
  parts.markers.clearDropMarkers()
  local eventUtils = overhaul_events_utils
  if eventUtils then eventUtils.restoreTrafficAmount() end
  guihooks.trigger('ClearTasklist')
end

-- Public API: shifts ------------------------------------------------------------------------------

function M.requestFacilityWorkState()
  if shiftEnded then
    parts.truckDrive.setNavigationPath(nil)
    parts.markers.clearDropMarkers()
    notifyPhoneState()
    return
  end
  refreshGuidanceMarkers()
  if selectedFacilityId and not currentForkliftId and not currentBatch and not truckState then
    parts.markers.setWaypointToFacilityForklift(selectedFacilityId)
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
    local maxB = tonumber(facilityConfigs[id].batchSize) or 8
    if preferredBatchSize and preferredBatchSize > maxB then
      preferredBatchSize = maxB
    end
    if not currentBatch and not currentForkliftId then
      if parts.markers.setWaypointToFacilityForklift(id) then
        overhaul_events_utils.displayMessage("Waypoint set to the loaner forklift.", 4)
      end
    end
  else
    selectedFacilityId = nil
    if not currentBatch and not currentForkliftId and not truckState then
      parts.truckDrive.setNavigationPath(nil)
      parts.markers.clearDropMarkers()
    end
  end
  notifyPhoneState()
end

function M.setBatchSize(size)
  local s = tonumber(size)
  if not s or s < 1 then
    return
  end
  loadConfig()
  local maxB = 8
  if selectedFacilityId and facilityConfigs[selectedFacilityId] then
    maxB = tonumber(facilityConfigs[selectedFacilityId].batchSize) or 8
  end
  preferredBatchSize = math.max(1, math.min(math.floor(s), maxB))
  notifyPhoneState()
end

function M.endFacilityWork()
  endShiftCleanup()
end

function M.isFacilityWorkActive()
  return selectedFacilityId ~= nil or currentBatch ~= nil or currentForkliftId ~= nil or truckState ~= nil
end

function M.repairForklift()
  return repairForklift()
end

function M.completeTruckLoading()
  if truckState ~= "waiting_for_load" or not truckRoadNodes or #truckRoadNodes == 0 or not truckVehicleId then return end
  local required = truckLoadTargetCount or TRUCK_LOAD_COUNT
  if #truckLoadPropIds < required then
    overhaul_events_utils.displayMessage(string.format("Load all %d %s onto the truck first.", required, truckLoadMaterialName or "items"), 4)
    return
  end
  local vehicleObject = be:getObjectByID(truckVehicleId)
  if not vehicleObject then
    clearTruckState()
    notifyPhoneState()
    return
  end
  local toIdx = #truckRoadNodes
  local lastNode = truckRoadNodes[toIdx]
  if not lastNode then return end
  truckTargetNodeIndex = toIdx - 1
  truckState = "driving_to_end"
  truckWaypointPhase = nil
  updateTasklistValues()
  -- Use overhaulDriver.returnTargetPosition (like quarry/loading) so truck drives from current position with no teleport/jump
  local exitPos = {
    x = lastNode.x or lastNode[1] or 0,
    y = lastNode.y or lastNode[2] or 0,
    z = lastNode.z or lastNode[3] or 0
  }
  parts.truckDrive.sendTruckDriveToPosition(vehicleObject, exitPos)
  if not currentBatch then
    parts.truckDrive.setNavigationPath(nil)
    refreshGuidanceMarkers()
    updateTasklistValues()
  end
  notifyPhoneState()
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  onUpdate(dtReal, dtSim, dtRaw)
end

-- One map POI per facility hub at parkingSpot (inspect/start) only.
function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  if not levelIdentifier or not elements then return end
  if not loadConfig() then return end
  for facilityId, facilityConfig in pairs(facilityConfigs) do
    local spotName = facilityConfig.parkingSpot
    if type(spotName) == "string" and spotName ~= "" then
      local spawnData = parts.sites.getForkliftSpawnPoint(spotName, facilityConfig)
      local position = spawnData and spawnData.pos
      if position then
        local label = facilityConfig.name
        if not label then
          local organization = overhaul_world_organizations.getOrganization(facilityConfig.organizationId or facilityId)
          label = organization and organization.name or nil
        end
        label = label or facilityId
        table.insert(elements, {
          id = "facilityWork_" .. facilityId,
          data = {
            type = "facilityWork",
            facilityId = facilityId,
          },
          markerInfo = {
            bigmapMarker = {
              pos = position,
              icon = "poi_pickup_round",
              name = label,
              description = "Facility work: load cargo with a forklift.",
              cardIcon = "boxTruck",
            },
          },
        })
      end
    end
  end
end

function M.onClientEndMission()
  if M.isFacilityWorkActive() then endShiftCleanup({ levelExit = true }) end
end

-- Settle shift pay before Ctrl+L can checkpoint the career and unload this extension.
-- These requests obey autosave off. Settled pay stays in session state for an explicit save;
-- ending the shift is not itself a claim that the career was saved.
function M.onOverhaulBeforeLuaReload()
  if not M.isFacilityWorkActive() then return end
  endShiftCleanup({ levelExit = true })
  require('overhaul/lib/save/store').request('facilityWork:reloadWages')
end

function M.onOverhaulBeforeSaveExit()
  if not M.isFacilityWorkActive() then return end
  endShiftCleanup({ levelExit = true })
  require('overhaul/lib/save/store').request('facilityWork:exitWages')
end

function M.onOverhaulActive(active)
  if active == false and M.isFacilityWorkActive() then
    endShiftCleanup({ levelExit = true, discardPay = true })
  end
end

-- Public API and game hooks -----------------------------------------------------------------------

M.onBeamNGTrigger = onBeamNGTrigger
M.onVehicleSwitched = onVehicleSwitched
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.activity = require('overhaul/jobs/facilityWork/activity')(M)

return M
