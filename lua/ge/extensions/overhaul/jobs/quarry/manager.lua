-- Quarry truck and cargo state, bed geometry, damage and stock returns.
-- Read state, props part, cleanup, truck operations, payload checks, damage and trip movement.
local quarrySettings = require("overhaul/jobs/quarry/settings")
local truckCommands = require('overhaul/lib/jobs/truckCommands')

local M = {}

local Config = overhaul_jobs_quarry_config
local truckRouteGeneration = 0

-- State -------------------------------------------------------------------------------------------

M.jobObjects = {
  truckID = nil,
  currentLoadMass = 0,
  lastDeliveredMass = 0,
  deliveredPropIds = nil,
  materialType = nil,
  activeGroup = nil,
  loadingZoneTargetPos = nil,
  truckSpawnQueued = false,
  itemDamage = {},
  totalItemDamagePercent = 0,
  anyItemDamaged = false,
  lastDeliveryDamagePercent = 0,
  deliveryDestination = nil,
  deliveryBlocksStatus = nil,
  zoneSwapPending = false,
  zoneSwapTargetZone = nil,
  zoneSwapTruckAtDestination = false,
  zoneSwapLoadedPropIds = nil,
  zoneSwapDeliveryBlocksStatus = nil,
  zoneSwapDeliveredMass = nil,
}

M.propQueue = {}
M.propQueueById = {}
M.itemInitialState = {}
M.itemDamageState = {}
M.debugDrawCache = {
  bedData = nil,
  nodePoints = {},
  itemPieces = {}
}

M.markerCleared = false
M.truckStoppedInLoading = false
M.truckNudging = false
M.truckNudgeModeSet = false
M.truckRouteStartTime = 0
M.isDispatching = false
M.payloadUpdateTimer = 0
M.truckStoppedTimer = 0
M.truckLastPosition = nil
M.deliveryTimer = 0
M.truckDamage = 0
M.damageCheckQueued = false
M.teleportQueued = false
M.teleportQueued = false

M.cachedBedData = {}
M.cachedMaterialConfigs = {}
M.cachedBoundingBoxes = {}
M.lastPayloadMass = 0
M.payloadStationaryCount = 0

-- Parts -------------------------------------------------------------------------------------------

local parts = {props = require('overhaul/jobs/quarry/props')(Config, M)}


-- Prop cleanup ----------------------------------------------------------------------------------

function M.clearUnloadedProps(oldActiveGroup)
  local loadedPropIds = {}
  local loadedSet = {}
  if M.jobObjects.truckID then
    local truck = be:getObjectByID(M.jobObjects.truckID)
    if truck then
      loadedPropIds = M.getLoadedPropIdsInTruck(0.1) or {}
      for _, id in ipairs(loadedPropIds) do
        loadedSet[id] = true
      end
    end
  end
  local stockReturned = {}
  oldActiveGroup = oldActiveGroup or M.jobObjects.activeGroup
  for i = #M.propQueue, 1, -1 do
    local entry = M.propQueue[i]
    local id = entry.id
    if id and not loadedSet[id] then
      local isDamaged = false
      if M.jobObjects.itemDamage and M.jobObjects.itemDamage[id] then
        isDamaged = M.jobObjects.itemDamage[id].isDamaged or false
      elseif M.itemDamageState[id] then
        isDamaged = M.itemDamageState[id].isDamaged or false
      end
      if not isDamaged and entry.materialType and oldActiveGroup then
        if not stockReturned[entry.materialType] then
          stockReturned[entry.materialType] = 0
        end
        stockReturned[entry.materialType] = stockReturned[entry.materialType] + 1
      end
      M.propQueueById[id] = nil
      M.itemInitialState[id] = nil
      M.itemDamageState[id] = nil
      local obj = be:getObjectByID(id)
      if obj then obj:delete() end
      table.remove(M.propQueue, i)
    end
  end
  if next(stockReturned) and oldActiveGroup then
    local Zones = extensions.overhaul_jobs_quarry_zones
    local Contracts = extensions.overhaul_jobs_quarry_contracts
    if Zones and Contracts and Contracts.getCurrentGameHour then
      local stockInfo = Zones.getZoneStockInfo(oldActiveGroup, Contracts.getCurrentGameHour)
      if stockInfo and stockInfo.materialStocks then
        for materialType, count in pairs(stockReturned) do
          local stock = stockInfo.materialStocks[materialType]
          if stock then
            stock.current = math.min(stock.current + count, stock.max)
          end
        end
      end
    end
  end
end

function M.clearProps()
  local stockReturned = {}
  for i = #M.propQueue, 1, -1 do
    local entry = M.propQueue[i]
    local id = entry.id
    if id then
      local isDamaged = false
      if M.jobObjects.itemDamage and M.jobObjects.itemDamage[id] then
        isDamaged = M.jobObjects.itemDamage[id].isDamaged or false
      elseif M.itemDamageState[id] then
        isDamaged = M.itemDamageState[id].isDamaged or false
      end
      if not isDamaged and entry.materialType and M.jobObjects.activeGroup then
        if not stockReturned[entry.materialType] then
          stockReturned[entry.materialType] = 0
        end
        stockReturned[entry.materialType] = stockReturned[entry.materialType] + 1
      end
      M.propQueueById[id] = nil
      M.itemInitialState[id] = nil
      M.itemDamageState[id] = nil
      local obj = be:getObjectByID(id)
      if obj then obj:delete() end
    end
    table.remove(M.propQueue, i)
  end
  if next(stockReturned) and M.jobObjects.activeGroup then
    local Zones = extensions.overhaul_jobs_quarry_zones
    local Contracts = extensions.overhaul_jobs_quarry_contracts
    if Zones and Contracts and Contracts.getCurrentGameHour then
      local stockInfo = Zones.getZoneStockInfo(M.jobObjects.activeGroup, Contracts.getCurrentGameHour)
      if stockInfo and stockInfo.materialStocks then
        for materialType, count in pairs(stockReturned) do
          local stock = stockInfo.materialStocks[materialType]
          if stock then
            stock.current = math.min(stock.current + count, stock.max)
          end
        end
      end
    end
  end
end

function M.cleanupStalePropEntries()
  local cleanedCount = 0
  for i = #M.propQueue, 1, -1 do
    local entry = M.propQueue[i]
    if entry and entry.id then
      local obj = be:getObjectByID(entry.id)
      if not obj then
        M.propQueueById[entry.id] = nil
        M.itemInitialState[entry.id] = nil
        M.itemDamageState[entry.id] = nil
        table.remove(M.propQueue, i)
        cleanedCount = cleanedCount + 1
      end
    end
  end
  return cleanedCount
end

function M.cleanupJob(deleteTruck, stateIdle)
  truckRouteGeneration = truckRouteGeneration + 1
  core_groundMarkers.setPath(nil)
  M.markerCleared = false
  M.truckStoppedInLoading = false
  M.truckNudging = false
  M.truckNudgeModeSet = false
  M.isDispatching = false
  M.payloadUpdateTimer = 0
  M.debugDrawCache.bedData = nil
  M.debugDrawCache.nodePoints = {}
  M.debugDrawCache.itemPieces = {}
  M.clearProps()
  if deleteTruck and M.jobObjects.truckID then
    M.cachedBedData[M.jobObjects.truckID] = nil
    local obj = be:getObjectByID(M.jobObjects.truckID)
    if obj then obj:delete() end
  end
  M.jobObjects.truckID = nil
  M.jobObjects.currentLoadMass = 0
  M.jobObjects.lastDeliveredMass = 0
  M.jobObjects.deliveredPropIds = nil
  M.jobObjects.materialType = nil
  M.jobObjects.activeGroup = nil
  M.jobObjects.deliveryDestination = nil
  M.jobObjects.deferredTruckTargetPos = nil
  M.jobObjects.loadingZoneTargetPos = nil
  M.jobObjects.truckSpawnQueued = false
  M.jobObjects.itemDamage = {}
  M.jobObjects.totalItemDamagePercent = 0
  M.jobObjects.anyItemDamaged = false
  M.jobObjects.lastDeliveryDamagePercent = 0
  M.jobObjects.deliveryBlocksStatus = nil
  M.jobObjects.zoneSwapPending = false
  M.jobObjects.zoneSwapTargetZone = nil
  M.jobObjects.zoneSwapTruckAtDestination = false
  M.jobObjects.zoneSwapLoadedPropIds = nil
  M.jobObjects.zoneSwapDeliveryBlocksStatus = nil
  M.jobObjects.zoneSwapDeliveredMass = nil
  M.itemDamageState = {}
  M.pendingRespawns = {}
  M.truckStoppedTimer = 0
  M.truckLastPosition = nil
  M.deliveryTimer = 0
  M.truckDamage = 0
  M.truckGroundSpeed = 0
  M.damageCheckQueued = false
  M.teleportQueued = false
  M.lastPayloadMass = 0
  M.payloadStationaryCount = 0
  return stateIdle
end

-- Truck commands --------------------------------------------------------------------------------

local function setupTruckAI(truck)
  if not truck then return end
  -- Quarry trucks are autonomous job vehicles, outside the traffic-role hook.
  -- The driver's synchronous route acceptance API requires Overhaul AI.
  if overhaul_shell_extensionManager and overhaul_shell_extensionManager.applyOverrideAI then
    overhaul_shell_extensionManager.applyOverrideAI(truck:getID())
  end
  truck:queueLuaCommand("if ai and ai.setPullOver then ai.setPullOver(false) end")
end

function M.spawnTruckForGroup(group, materialType, targetPos)
  if not group or not group.spawn or not group.spawn.pos then return nil end
  local matConfig = M.getMaterialConfig(materialType)
  if not matConfig or not matConfig.deliveryVehicle then
    return nil
  end
  local truckModel = matConfig.deliveryVehicle.model
  local truckConfig = matConfig.deliveryVehicle.config
  local position, rotation = M.calculateSpawnTransformForLocation(vec3(group.spawn.pos), targetPos)
  local truck = core_vehicles.spawnNewVehicle(truckModel, { pos = position, rot = rotation, config = truckConfig, autoEnterVehicle = false })
  if not truck then return nil end
  local truckId = truck:getID()
  local truckObj = be:getObjectByID(truckId)
  if truckObj then
    setupTruckAI(truckObj)
  end
  return truckId
end

function M.driveTruckToPoint(truckId, targetPos)
  local truck = be:getObjectByID(truckId)
  if not truck then return end
  truckRouteGeneration = truckRouteGeneration + 1
  local generation = truckRouteGeneration
  M.truckNudging = false
  M.truckNudgeModeSet = false
  M.truckRouteStartTime = os.clock()
  truck:queueLuaCommand('if not overhaulDriver then extensions.load("overhaulDriver") end')
  -- Stay parked in neutral while the asynchronous route is being prepared.
  truck:queueLuaCommand(truckCommands.holdTruck())
  setupTruckAI(truck)
  core_jobsystem.create(function(job)
    job.sleep(0.5)
    if generation ~= truckRouteGeneration or be:getObjectByID(truckId) ~= truck then return end
    truck:queueLuaCommand("if ai.setAvoidCars then ai.setAvoidCars('off') end")
    job.sleep(0.1)
    if generation ~= truckRouteGeneration or be:getObjectByID(truckId) ~= truck then return end
    -- Stock route installation selects arcade mode. Release after it has taken
    -- control, including the explicit clutch input used by the neutral hold.
    truck:queueLuaCommand(truckCommands.routeTruck(serialize(targetPos)))
  end)
end

function M.stopTruck(truckId)
  truckRouteGeneration = truckRouteGeneration + 1
  local truck = be:getObjectByID(truckId)
  if not truck then return end
  M.truckNudgeModeSet = false
  M.truckNudging = false
  truck:queueLuaCommand(truckCommands.holdTruck())
end

function M.nudgeTruckForward(truckId, throttle)
  local truck = be:getObjectByID(truckId)
  if not truck then return end
  throttle = throttle or 0.3
  if not M.truckNudgeModeSet then
    truckRouteGeneration = truckRouteGeneration + 1
    truck:queueLuaCommand(truckCommands.beginTruckNudge())
    M.truckNudgeModeSet = true
  end
  truck:queueLuaCommand("input.event('parkingbrake', 0, 1)")
  truck:queueLuaCommand("input.event('brake', 0, 1)")
  truck:queueLuaCommand("input.event('throttle', " .. throttle .. ", 1)")
end

function M.nudgeTruckWithControl(truckId, throttle, brake, steering)
  local truck = be:getObjectByID(truckId)
  if not truck then return end
  throttle = throttle or 0
  brake = brake or 0
  steering = steering or 0
  if not M.truckNudgeModeSet then
    truckRouteGeneration = truckRouteGeneration + 1
    truck:queueLuaCommand(truckCommands.beginTruckNudge())
    M.truckNudgeModeSet = true
  end
  truck:queueLuaCommand("input.event('parkingbrake', 0, 1)")
  truck:queueLuaCommand("input.event('throttle', " .. throttle .. ", 1)")
  truck:queueLuaCommand("input.event('brake', " .. brake .. ", 1)")
  truck:queueLuaCommand("input.event('steering', " .. steering .. ", 2)")
end

function M.stopNudging(truckId)
  M.stopTruck(truckId)
end

function M.getLoadingZoneTargetPos(group)
  if not group then return nil end
  if group.stopLocations and #group.stopLocations > 0 and group.stopLocations[1] and group.stopLocations[1].pos then
    return vec3(group.stopLocations[1].pos)
  end
  if group.loading and group.loading.center then
    return vec3(group.loading.center)
  end
  return nil
end

-- Truck bed and payload -------------------------------------------------------------------------

function M.getTruckBedData(obj)
  if not obj then return nil end
  local truckId = obj:getID()
  if M.cachedBedData[truckId] then
    local cached = M.cachedBedData[truckId]
    local position = obj:getPosition()
    local forwardDirection = obj:getDirectionVector():normalized()
    local upDirection = obj:getDirectionVectorUp():normalized()
    local rightDirection = forwardDirection:cross(upDirection):normalized()
    upDirection = rightDirection:cross(forwardDirection):normalized()
    local geometry = quarrySettings.bedGeometry(cached.settings)
    local offsetBack, offsetSide = geometry.offsetBack, geometry.offsetSide
    local bedCenterHeight = geometry.floorHeight + (geometry.centerLoadHeight / 2)
    local bedCenter = position - (forwardDirection * offsetBack) + (rightDirection * offsetSide) + (upDirection * bedCenterHeight)
    cached.center = bedCenter
    cached.axisX = rightDirection
    cached.axisY = forwardDirection
    cached.axisZ = upDirection
    return cached
  end
  local position = obj:getPosition()
  local forwardDirection = obj:getDirectionVector():normalized()
  local upDirection = obj:getDirectionVectorUp():normalized()
  local rightDirection = forwardDirection:cross(upDirection):normalized()
  upDirection = rightDirection:cross(forwardDirection):normalized()
  local modelName = obj:getJBeamFilename()
  local bedSettings = Config.bedSettings and Config.bedSettings[modelName]
  if not bedSettings then
    local materialType = M.jobObjects.materialType
    local matConfig = M.getMaterialConfig(materialType)
    if matConfig and matConfig.deliveryVehicle and matConfig.deliveryVehicle.bedSettings then
      bedSettings = Config.bedSettings and Config.bedSettings[matConfig.deliveryVehicle.bedSettings]
    end
  end
  if not bedSettings then
    bedSettings = Config.bedSettings and (Config.bedSettings[next(Config.bedSettings)] or Config.bedSettings.dumptruck)
  end
  if not bedSettings then return nil end
  local geometry = quarrySettings.bedGeometry(bedSettings)
  local offsetBack, offsetSide = geometry.offsetBack, geometry.offsetSide
  local bedCenterHeight = geometry.floorHeight + (geometry.centerLoadHeight / 2)
  local bedCenter = position - (forwardDirection * offsetBack) + (rightDirection * offsetSide) + (upDirection * bedCenterHeight)
  local bedData = {
    center = bedCenter, axisX = rightDirection, axisY = forwardDirection, axisZ = upDirection,
    halfWidth = geometry.width / 2, halfLength = geometry.length / 2,
    halfHeight = geometry.loadHeight / 2, floorHeight = geometry.floorHeight,
    settings = bedSettings
  }
  M.cachedBedData[truckId] = bedData
  return bedData
end

function M.isPointInTruckBed(point, bedData)
  if not bedData then return false end
  local diff = point - bedData.center
  local localX, localY, localZ = diff:dot(bedData.axisX), diff:dot(bedData.axisY), diff:dot(bedData.axisZ)
  return (math.abs(localX) <= bedData.halfWidth and math.abs(localY) <= bedData.halfLength and math.abs(localZ) <= bedData.halfHeight)
end

local function payloadNodeCounts(obj, bedData, nodeStep)
  local tf = obj:getTransform()
  local axisX, axisY, axisZ = tf:getColumn(0), tf:getColumn(1), tf:getColumn(2)
  local objPos, nodeCount = obj:getPosition(), obj:getNodeCount()
  local nodesInside, nodesChecked = 0, 0
  if nodeCount > 0 then
    local lastChecked = -1
    for i = 0, nodeCount - 1, nodeStep do
      nodesChecked = nodesChecked + 1
      lastChecked = i
      local worldPoint = objPos - (axisX * obj:getNodePosition(i).x) - (axisY * obj:getNodePosition(i).y) + (axisZ * obj:getNodePosition(i).z)
      if M.isPointInTruckBed(worldPoint, bedData) then nodesInside = nodesInside + 1 end
    end
    if lastChecked ~= nodeCount - 1 then
      nodesChecked = nodesChecked + 1
      local worldPoint = objPos - (axisX * obj:getNodePosition(nodeCount - 1).x) - (axisY * obj:getNodePosition(nodeCount - 1).y) + (axisZ * obj:getNodePosition(nodeCount - 1).z)
      if M.isPointInTruckBed(worldPoint, bedData) then nodesInside = nodesInside + 1 end
    end
  end
  return nodesInside, nodesChecked
end

local function calculatePayloadForProps(propEntries, bedData, materialType, includeDamaged)
  local matConfig = M.getMaterialConfig(materialType)
  local defaultMass = 0
  if matConfig and matConfig.unitType == "mass" then
    defaultMass = matConfig.massPerProp or 41000
  end
  local nodeStep = quarrySettings.value(Config.settings.payload, "payload", "nodeSamplingStep")
  local totalMass = 0
  for _, rockEntry in ipairs(propEntries) do
    if not includeDamaged and M.jobObjects.itemDamage and M.jobObjects.itemDamage[rockEntry.id] and M.jobObjects.itemDamage[rockEntry.id].isDamaged then
    else
      local obj = be:getObjectByID(rockEntry.id)
      if obj then
        local entryMass = rockEntry.mass
        if not entryMass and rockEntry.materialType then
          local entryMatConfig = M.getMaterialConfig(rockEntry.materialType)
          if entryMatConfig and entryMatConfig.unitType == "mass" then
            entryMass = entryMatConfig.massPerProp or 41000
          end
        end
        entryMass = entryMass or defaultMass
        local nodesInside, nodesChecked = payloadNodeCounts(obj, bedData, nodeStep)
        if nodesChecked > 0 then
          local contribution = entryMass * (nodesInside / nodesChecked)
          totalMass = totalMass + contribution
        end
      end
    end
  end
  return totalMass
end

function M.calculateTruckPayload()
  M.cleanupStalePropEntries()
  if #M.propQueue == 0 or not M.jobObjects.truckID then
    M.lastPayloadMass = 0
    return 0
  end
  local truck = be:getObjectByID(M.jobObjects.truckID)
  if not truck then
    M.lastPayloadMass = 0
    return 0
  end
  local materialType = M.jobObjects.materialType
  if not materialType then
    return 0
  end
  local matConfig = M.getMaterialConfig(materialType)
  if matConfig and matConfig.unitType == "item" then
    M.lastPayloadMass = 0
    return 0
  end
  local bedData = M.getTruckBedData(truck)
  if not bedData then
    M.lastPayloadMass = 0
    return 0
  end
  M.debugDrawCache.bedData = bedData
  local totalMass = calculatePayloadForProps(M.propQueue, bedData, materialType, true)
  M.lastPayloadMass = totalMass
  return totalMass
end

function M.calculateUndamagedTruckPayload()
  if #M.propQueue == 0 or not M.jobObjects.truckID then return 0 end
  local truck = be:getObjectByID(M.jobObjects.truckID)
  if not truck then return 0 end
  local materialType = M.jobObjects.materialType
  if not materialType then
    return 0
  end
  local matConfig = M.getMaterialConfig(materialType)
  if matConfig and matConfig.unitType == "item" then
    return 0
  end
  local bedData = M.getTruckBedData(truck)
  if not bedData then return 0 end
  return calculatePayloadForProps(M.propQueue, bedData, materialType, false)
end

-- Item damage -----------------------------------------------------------------------------------

function M.captureItemInitialState(objId)
  local obj = be:getObjectByID(objId)
  if not obj then return end
  M.itemInitialState[objId] = { nodeCount = obj:getNodeCount(), captureTime = os.clock(), captured = true }
  M.itemDamageState[objId] = { isDamaged = false, lastUpdate = 0 }
end

local function chargeDamagedItemReputation(matConfig, materialType)
  if matConfig.reputationLoss and matConfig.damage then
    local career = overhaul_career_career
    if career and type(career.isActive) == "function" and career.isActive() then
      local activeGroup = M.jobObjects.activeGroup
      if activeGroup and activeGroup.associatedOrganization then
        local organizationId = activeGroup.associatedOrganization
        local paymentModule = overhaul_career_economy_payment
        if paymentModule and type(paymentModule.reward) == "function" then
          local reputationAttributeKey = organizationId .. "Reputation"
          paymentModule.reward({
            [reputationAttributeKey] = { amount = -matConfig.reputationLoss }
          }, { label = string.format("Damaged %s", matConfig.name or materialType), tags = {"gameplay", "loading", "reputation"} })
        end
      end
    end
  end
end

local function repairNewItemDamage(isDamaged, wasDamaged, rockEntry, matConfig, materialType)
  if isDamaged and not wasDamaged then
    local Contracts = overhaul_jobs_quarry_contracts
    local Zones = overhaul_jobs_quarry_zones
    if Contracts and Zones then
      M.repairAndRespawnDamagedItem(rockEntry.id, Zones, Contracts)
    end
    chargeDamagedItemReputation(matConfig, materialType)
  end
end

local function queueItemDamageCheck(obj, rockEntry, matConfig, damageCache)
  if not damageCache or (os.clock() - damageCache.lastUpdate) > 0.5 then
    local ignoreList = matConfig.damage and matConfig.damage.ignore or {}
    local threshold = matConfig.damage and matConfig.damage.damageThreshold or 0.01
    local ignoreStr = ""
    if #ignoreList > 0 then
      local patterns = {}
      for _, p in ipairs(ignoreList) do table.insert(patterns, string.format('"%s"', p:lower())) end
      ignoreStr = "local patterns = {" .. table.concat(patterns, ",") .. "} "
      ignoreStr = ignoreStr .. "for _, p in ipairs(patterns) do if string.find(string.lower(k), p) then shouldIgnore = true; break end end "
    end
    local luaCmd = string.format('obj:queueGameEngineLua(require("vehicle/overhaul/geCallback").reply(' .. require('overhaul/lib/vehicles/callbacks').open('loadingItemDamage', {owner = 'loading', vehId = obj:getID()}) .. ', "loadingItemDamage", "' .. rockEntry.id .. ', " .. tostring(beamstate and beamstate.getPartDamageData and (function() for k,v in pairs(beamstate.getPartDamageData()) do local shouldIgnore = false; %s if not shouldIgnore and v.damage > %f then return true end end return false end)())))', ignoreStr, threshold)
    obj:queueLuaCommand(luaCmd)
  end
end

local function scanItemDamage(matConfig, materialType, totalDamage, damagedCount, checkedCount)
  for _, rockEntry in ipairs(M.propQueue) do
    local obj = be:getObjectByID(rockEntry.id)
    if obj then
      checkedCount = checkedCount + 1
      if not M.itemInitialState[rockEntry.id] then M.captureItemInitialState(rockEntry.id) end
      local initialState = M.itemInitialState[rockEntry.id]
      if initialState and (os.clock() - initialState.captureTime) < 2.0 then
        M.jobObjects.itemDamage[rockEntry.id] = { damage = 0, isDamaged = false, settling = true, brokenPieces = 0 }
      else
        local damageCache = M.itemDamageState[rockEntry.id]
        queueItemDamageCheck(obj, rockEntry, matConfig, damageCache)
        local isDamaged = damageCache and damageCache.isDamaged or false
        local wasDamaged = M.jobObjects.itemDamage[rockEntry.id] and M.jobObjects.itemDamage[rockEntry.id].isDamaged or false
        local damagePercent = isDamaged and 1 or 0
        M.jobObjects.itemDamage[rockEntry.id] = { damage = damagePercent, isDamaged = isDamaged, brokenPieces = isDamaged and 1 or 0 }
        repairNewItemDamage(isDamaged, wasDamaged, rockEntry, matConfig, materialType)
        if not M.propQueueById[rockEntry.id] then
          checkedCount = checkedCount - 1
        else
          totalDamage = totalDamage + damagePercent
          if isDamaged then damagedCount = damagedCount + 1 end
        end
      end
    end
  end
  return totalDamage, damagedCount, checkedCount
end

function M.calculateItemDamage()
  local materialType = M.jobObjects.materialType
  if not materialType then
    return 0
  end
  local matConfig = M.getMaterialConfig(materialType)
  if not matConfig or matConfig.unitType ~= "item" or #M.propQueue == 0 then
    M.jobObjects.itemDamage, M.jobObjects.totalItemDamagePercent, M.jobObjects.anyItemDamaged = {}, 0, false
    M.debugDrawCache.itemPieces = {}
    return
  end
  local totalDamage, damagedCount, checkedCount = 0, 0, 0
  totalDamage, damagedCount, checkedCount = scanItemDamage(matConfig, materialType, totalDamage, damagedCount, checkedCount)
  if checkedCount > 0 then
    M.jobObjects.totalItemDamagePercent = (totalDamage / checkedCount) * 100
    M.jobObjects.anyItemDamaged = damagedCount > 0
  else
    M.jobObjects.totalItemDamagePercent, M.jobObjects.anyItemDamaged = 0, false
  end
end

-- Loaded stock and prop return ------------------------------------------------------------------

function M.getLoadedPropIdsInTruck(minRatio)
  minRatio = minRatio or (quarrySettings.value(Config.settings.payload, "payload", "minLoadRatio"))
  if #M.propQueue == 0 or not M.jobObjects.truckID then return {} end
  local truck = be:getObjectByID(M.jobObjects.truckID)
  if not truck then return {} end
  local bedData = M.getTruckBedData(truck)
  if not bedData then return {} end
  local nodeStep = quarrySettings.value(Config.settings.payload, "payload", "nodeSamplingStep")
  local ids = {}
  for _, rockEntry in ipairs(M.propQueue) do
    local obj = be:getObjectByID(rockEntry.id)
    if obj then
      local tf = obj:getTransform()
      local axisX, axisY, axisZ = tf:getColumn(0), tf:getColumn(1), tf:getColumn(2)
      local objPos, nodeCount = obj:getPosition(), obj:getNodeCount()
      local nodesInside, nodesChecked = 0, 0
      if nodeCount > 0 then
        local lastChecked = -1
        for i = 0, nodeCount - 1, nodeStep do
          nodesChecked = nodesChecked + 1
          lastChecked = i
          if M.isPointInTruckBed(objPos - (axisX * obj:getNodePosition(i).x) - (axisY * obj:getNodePosition(i).y) + (axisZ * obj:getNodePosition(i).z), bedData) then nodesInside = nodesInside + 1 end
        end
        if lastChecked ~= nodeCount - 1 then
          nodesChecked = nodesChecked + 1
          if M.isPointInTruckBed(objPos - (axisX * obj:getNodePosition(nodeCount - 1).x) - (axisY * obj:getNodePosition(nodeCount - 1).y) + (axisZ * obj:getNodePosition(nodeCount - 1).z), bedData) then nodesInside = nodesInside + 1 end
        end
      end
      if nodesChecked > 0 and (nodesInside / nodesChecked) >= minRatio then table.insert(ids, rockEntry.id) end
    end
  end
  return ids
end

function M.getBlockLoadRatio(blockId)
  if not M.jobObjects.truckID then return 0 end
  local truck = be:getObjectByID(M.jobObjects.truckID)
  if not truck then return 0 end
  local bedData = M.getTruckBedData(truck)
  if not bedData then return 0 end
  local obj = be:getObjectByID(blockId)
  if not obj then return 0 end
  local tf = obj:getTransform()
  local axisX, axisY, axisZ = tf:getColumn(0), tf:getColumn(1), tf:getColumn(2)
  local objPos, nodeCount = obj:getPosition(), obj:getNodeCount()
  local nodeStep = quarrySettings.value(Config.settings.payload, "payload", "nodeSamplingStep")
  local nodesInside, nodesChecked = 0, 0
  if nodeCount > 0 then
    local lastChecked = -1
    for i = 0, nodeCount - 1, nodeStep do
      nodesChecked = nodesChecked + 1
      lastChecked = i
      if M.isPointInTruckBed(objPos - (axisX * obj:getNodePosition(i).x) - (axisY * obj:getNodePosition(i).y) + (axisZ * obj:getNodePosition(i).z), bedData) then nodesInside = nodesInside + 1 end
    end
    if lastChecked ~= nodeCount - 1 then
      nodesChecked = nodesChecked + 1
      if M.isPointInTruckBed(objPos - (axisX * obj:getNodePosition(nodeCount - 1).x) - (axisY * obj:getNodePosition(nodeCount - 1).y) + (axisZ * obj:getNodePosition(nodeCount - 1).z), bedData) then nodesInside = nodesInside + 1 end
    end
  end
  return nodesChecked > 0 and (nodesInside / nodesChecked) or 0
end

function M.getItemBlocksStatus()
  local blocks = {}
  for i, rockEntry in ipairs(M.propQueue) do
    local loadRatio = M.getBlockLoadRatio(rockEntry.id)
    table.insert(blocks, {
      index = i, id = rockEntry.id, loadRatio = loadRatio, isLoaded = loadRatio >= 0.1,
      isDamaged = M.jobObjects.itemDamage and M.jobObjects.itemDamage[rockEntry.id] and M.jobObjects.itemDamage[rockEntry.id].isDamaged or false
    })
  end
  return blocks
end

function M.consumeZoneStock(group, deliveredPropIds, zonesModule, contractsModule)
  if not group then return end
  local cache = zonesModule.ensureGroupCache(group, contractsModule.getCurrentGameHour)
  if not cache or not cache.materialStocks then return end
  local deliveredSet = {}
  if type(deliveredPropIds) == "table" then
    for _, id in ipairs(deliveredPropIds) do deliveredSet[id] = true end
  end
  local materialMass = {}
  local materialCounts = {}
  for _, entry in ipairs(M.propQueue) do
    if entry.materialType and (next(deliveredSet) == nil or deliveredSet[entry.id]) then
      materialCounts[entry.materialType] = (materialCounts[entry.materialType] or 0) + 1
      materialMass[entry.materialType] = (materialMass[entry.materialType] or 0) + (entry.mass or 0)
    end
  end
  for matKey, count in pairs(materialCounts) do
    local stock = cache.materialStocks[matKey]
    if stock then
      local matConfig = M.getMaterialConfig(matKey)
      if matConfig and matConfig.unitType == "mass" then
        local massKg = (materialMass[matKey] or 0)
        stock.current = math.max(0, stock.current - massKg)
      else
        stock.current = math.max(0, stock.current - count)
      end
      if cache.spawnedPropCounts and cache.spawnedPropCounts[matKey] then
        cache.spawnedPropCounts[matKey] = math.max(0, cache.spawnedPropCounts[matKey] - count)
      end
    end
  end
end

function M.returnPropsToStock(propIds, zonesModule, contractsModule)
  if not propIds or #propIds == 0 then return end
  if not M.jobObjects.activeGroup then return end
  local idSet = {}
  for _, id in ipairs(propIds) do idSet[id] = true end
  local materialCounts = {}
  local materialMass = {}
  for _, entry in ipairs(M.propQueue) do
    if entry.id and idSet[entry.id] and entry.materialType then
      materialCounts[entry.materialType] = (materialCounts[entry.materialType] or 0) + 1
      materialMass[entry.materialType] = (materialMass[entry.materialType] or 0) + (entry.mass or 0)
    end
  end
  local cache = zonesModule.ensureGroupCache(M.jobObjects.activeGroup, contractsModule.getCurrentGameHour)
  if cache and cache.materialStocks then
    for matKey, count in pairs(materialCounts) do
      local stock = cache.materialStocks[matKey]
      if stock then
        local matConfig = M.getMaterialConfig(matKey)
        if matConfig and matConfig.unitType == "mass" then
          local massKg = (materialMass[matKey] or 0)
          stock.current = math.min(stock.current + massKg, stock.max)
        else
          stock.current = math.min(stock.current + count, stock.max)
        end
        if cache.spawnedPropCounts and cache.spawnedPropCounts[matKey] then
          cache.spawnedPropCounts[matKey] = math.max(0, cache.spawnedPropCounts[matKey] - count)
        end
      end
    end
  end
end

function M.despawnPropIds(propIds, zonesModule, contractsModule, skipStockConsumption)
  if not propIds or #propIds == 0 then return end
  local idSet = {}
  for _, id in ipairs(propIds) do idSet[id] = true end
  local removedEntries = {}
  for i = #M.propQueue, 1, -1 do
    local entry = M.propQueue[i]
    local id = entry.id
    if id and idSet[id] then
      table.insert(removedEntries, { materialType = entry.materialType, mass = entry.mass or 0 })
      M.propQueueById[id] = nil
      M.itemInitialState[id], M.itemDamageState[id] = nil, nil
      local obj = be:getObjectByID(id)
      if obj then obj:delete() end
      table.remove(M.propQueue, i)
    end
  end
  if #removedEntries > 0 and M.jobObjects.activeGroup and not skipStockConsumption then
    local cache = zonesModule.ensureGroupCache(M.jobObjects.activeGroup, contractsModule.getCurrentGameHour)
    if cache and cache.materialStocks then
      local materialMass = {}
      local materialCounts = {}
      for _, entry in ipairs(removedEntries) do
        if entry.materialType then
          materialCounts[entry.materialType] = (materialCounts[entry.materialType] or 0) + 1
          materialMass[entry.materialType] = (materialMass[entry.materialType] or 0) + (entry.mass or 0)
        end
      end
      for matKey, count in pairs(materialCounts) do
        local stock = cache.materialStocks[matKey]
        if stock then
          local matConfig = M.getMaterialConfig(matKey)
          if matConfig and matConfig.unitType == "mass" then
            local massKg = (materialMass[matKey] or 0)
            stock.current = math.max(0, stock.current - massKg)
          else
            stock.current = math.max(0, stock.current - count)
          end
          if cache.spawnedPropCounts and cache.spawnedPropCounts[matKey] then
            cache.spawnedPropCounts[matKey] = math.max(0, cache.spawnedPropCounts[matKey] - count)
          end
        end
      end
    end
  end
end

local function recoverStalledTruck(truckPos, truck)
  local roadName, nodeIdx = map.findClosestRoad(truckPos)
  if not (roadName and nodeIdx) then return end
  local mapData = map.getMap()
  local node = mapData and mapData.nodes and mapData.nodes[nodeIdx]
  if not (node and node.pos) then return end
  local roadNodePos = vec3(node.pos)
  local truckRot = truck:getRotation()
  spawn.safeTeleport(truck, roadNodePos, truckRot, nil, nil, nil, true)
  M.truckStoppedTimer = 0
  M.truckLastPosition = roadNodePos
  M.teleportQueued = true
  M.truckNudging = false
  M.truckRouteStartTime = os.clock()
end

-- Truck movement ----------------------------------------------------------------------------------

function M.handleTruckMovement(dtRealSeconds, destinationPosition, contractsModule)
  if not M.jobObjects.truckID or not destinationPosition then return end
  local truck = be:getObjectByID(M.jobObjects.truckID)
  if not truck then
    local zoneTag = M.jobObjects.activeGroup and M.jobObjects.activeGroup.secondaryTag
    local contractsConfig = zoneTag and contractsModule.getContractsConfig and contractsModule.getContractsConfig(zoneTag) or {}
    local crashPenalty = contractsConfig.crashPenalty or 0
    contractsModule.failContract(crashPenalty, "Truck destroyed! Contract failed.", "warning", M.cleanupJob)
    return
  end
  local arrivalDist = quarrySettings.value(Config.settings.truck, "truck", "arrivalDistanceThreshold")
  local truckPos = truck:getPosition()
  if (truckPos - destinationPosition):length() < arrivalDist then
    M.truckStoppedTimer, M.truckLastPosition = 0, nil
    M.truckDamage = 0
    M.damageCheckQueued = false
    M.teleportQueued = false
    return true
  end
  M.deliveryTimer = M.deliveryTimer + dtRealSeconds
  local posChange = M.truckLastPosition and (truckPos - M.truckLastPosition):length() or 0
  local velocity = truck:getVelocity()
  local speed = velocity and velocity:length() or 0
  local isMoving = speed > 1.0 or posChange > 1.0
  if isMoving then
    M.truckStoppedTimer, M.truckLastPosition = 0, truckPos
    M.truckDamage = 0
    M.damageCheckQueued = false
    M.teleportQueued = false
  elseif M.truckLastPosition then
    if posChange < 1.0 and speed < 1.0 then
      M.truckStoppedTimer = M.truckStoppedTimer + dtRealSeconds
      if M.truckStoppedTimer >= 10.0 then
        if not M.damageCheckQueued then
          truck:queueLuaCommand('if beamstate and beamstate.damage then obj:queueGameEngineLua(require("vehicle/overhaul/geCallback").reply(' .. require('overhaul/lib/vehicles/callbacks').open('loadingTruckDamage', {owner = 'loading', vehId = truck:getID()}) .. ', "loadingTruckDamage", tostring(beamstate.damage))) end')
          M.damageCheckQueued = true
        end
        if M.truckDamage and M.truckDamage > 100000 then
          return "damaged", M.deliveryTimer
        end
      end
      if M.truckStoppedTimer >= 30.0 then
        if not M.teleportQueued and (not M.truckDamage or M.truckDamage <= 100000) then
          recoverStalledTruck(truckPos, truck)
        end
      end
    else
      M.truckStoppedTimer, M.truckLastPosition = 0, truckPos
      M.truckDamage = 0
      M.truckGroundSpeed = 0
      M.damageCheckQueued = false
      M.teleportQueued = false
    end
  else
    M.truckLastPosition = truckPos
  end
  return false
end

function M.beginActiveContractTrip(contractsModule, zonesModule, uiMod)
  local contract = contractsModule.ContractSystem.activeContract
  if not contract or not contract.group then return false end
  if M.isDispatching then return false end
  M.isDispatching = true
  if uiMod then uiMod.uiHidden = false end
  M.jobObjects.activeGroup = contract.group
  M.jobObjects.materialType = contract.group.materialType or contract.material
  if not M.jobObjects.materialType then
    return false
  end
  M.jobObjects.deliveryDestination = contract.destination
  M.markerCleared = false
  M.truckStoppedInLoading = false
  M.truckNudging = false
  M.payloadUpdateTimer = 0
  local targetPos = M.getLoadingZoneTargetPos(M.jobObjects.activeGroup)
  if targetPos then
    core_groundMarkers.setPath(targetPos)
  end
  if #M.propQueue == 0 then
    M.spawnJobMaterials(contractsModule, zonesModule)
  end
  M.jobObjects.loadingZoneTargetPos = targetPos
  M.jobObjects.truckID = nil
  M.jobObjects.truckSpawnQueued = false
  M.isDispatching = false
  return true
end

function M.onTruckDamageCallback(damage)
  M.truckDamage = damage or 0
  M.damageCheckQueued = false
end

-- Public prop operations --------------------------------------------------------------------------

-- Public prop operations use the same owner state as the truck operations.
M.calculateSpawnTransformForLocation = parts.props.calculateSpawnTransformForLocation
M.getMaterialConfig = parts.props.getMaterialConfig
M.getMaterialBoundingBox = parts.props.getMaterialBoundingBox
M.generateGridPositions = parts.props.generateGridPositions
M.managePropCapacity = parts.props.managePropCapacity
M.deleteDamagedItem = parts.props.deleteDamagedItem
M.repairAndRespawnDamagedItem = parts.props.repairAndRespawnDamagedItem
M.processPendingRespawns = parts.props.processPendingRespawns
M.respawnMassMaterials = parts.props.respawnMassMaterials
M.spawnJobMaterials = parts.props.spawnJobMaterials
-- Game hooks --------------------------------------------------------------------------------------

M.onExtensionLoaded = function()
end
M.loadingConfigLoaded = function()
  Config = overhaul_jobs_quarry_config
  parts.props.set_Config(Config)
end

return M
