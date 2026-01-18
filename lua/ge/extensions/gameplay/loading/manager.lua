local M = {}

local Config = gameplay_loading_config

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

function M.calculateSpawnTransformForLocation(spawnPos, targetPos)
  local dir = vec3(0, 1, 0)
  if targetPos and map and map.findClosestRoad and map.getPath and map.getMap then
    local spawnRoadName, spawnNodeIdx, spawnDist = map.findClosestRoad(spawnPos)
    local targetRoadName, targetNodeIdx, targetDist = map.findClosestRoad(targetPos)
    
    if spawnRoadName and targetRoadName then
      local mapData = map.getMap()
      if mapData and mapData.nodes then
        local path = nil
        if spawnRoadName ~= targetRoadName then
          path = map.getPath(spawnRoadName, targetRoadName)
        end
        
        local nextNodeIdx = nil
        local spawnPosVec = vec3(spawnPos)
        
        if path and #path > 0 then
          local closestPathIdx = 1
          local closestDist = math.huge
          for i, nodeIdx in ipairs(path) do
            local node = mapData.nodes[nodeIdx]
            if node and node.pos then
              local nodePos = vec3(node.pos)
              local dist = (nodePos - spawnPosVec):length()
              if dist < closestDist then
                closestDist = dist
                closestPathIdx = i
              end
            end
          end
          
          if closestPathIdx < #path then
            nextNodeIdx = path[closestPathIdx + 1]
          elseif #path > 1 then
            nextNodeIdx = path[2]
          else
            nextNodeIdx = path[1]
          end
        elseif spawnRoadName == targetRoadName and spawnNodeIdx and targetNodeIdx then
          local roadData = mapData.roads and mapData.roads[spawnRoadName]
          if roadData and roadData.nodes then
            local spawnNodeInRoad = nil
            local targetNodeInRoad = nil
            for i, nodeIdx in ipairs(roadData.nodes) do
              if nodeIdx == spawnNodeIdx then
                spawnNodeInRoad = i
              end
              if nodeIdx == targetNodeIdx then
                targetNodeInRoad = i
              end
            end
            
            if spawnNodeInRoad and targetNodeInRoad then
              if targetNodeInRoad > spawnNodeInRoad and spawnNodeInRoad < #roadData.nodes then
                nextNodeIdx = roadData.nodes[spawnNodeInRoad + 1]
              elseif targetNodeInRoad < spawnNodeInRoad and spawnNodeInRoad > 1 then
                nextNodeIdx = roadData.nodes[spawnNodeInRoad - 1]
              elseif spawnNodeInRoad < #roadData.nodes then
                nextNodeIdx = roadData.nodes[spawnNodeInRoad + 1]
              elseif spawnNodeInRoad > 1 then
                nextNodeIdx = roadData.nodes[spawnNodeInRoad - 1]
              end
            end
          end
        end
        
        if nextNodeIdx then
          local nextNode = mapData.nodes[nextNodeIdx]
          if nextNode and nextNode.pos then
            local nextNodePos = vec3(nextNode.pos)
            local pathDir = nextNodePos - spawnPosVec
            pathDir.z = 0
            if pathDir:length() > 0.1 then
              dir = pathDir:normalized()
            end
          end
        end
      end
    end
    
    if dir:length() < 0.1 then
      local targetDir = vec3(targetPos) - spawnPos
      targetDir.z = 0
      if targetDir:length() > 0 then dir = targetDir:normalized() end
    end
  elseif targetPos then
    local targetDir = vec3(targetPos) - spawnPos
    targetDir.z = 0
    if targetDir:length() > 0 then dir = targetDir:normalized() end
  end
  
  local normal = vec3(0,0,1)
  if map and map.surfaceNormal then normal = map.surfaceNormal(spawnPos, 1) end
  if dir:length() == 0 then dir = vec3(0,1,0) end
  local rotation = quatFromDir(dir, normal)
  return spawnPos, rotation
end

function M.getMaterialConfig(materialType)
  if M.cachedMaterialConfigs[materialType] then
    return M.cachedMaterialConfigs[materialType]
  end
  local matConfig = Config.materials and Config.materials[materialType]
  if matConfig then
    M.cachedMaterialConfigs[materialType] = matConfig
  end
  return matConfig
end

function M.getMaterialBoundingBox(materialType)
  if M.cachedBoundingBoxes[materialType] then
    return M.cachedBoundingBoxes[materialType]
  end
  
  local matConfig = M.getMaterialConfig(materialType)
  if not matConfig then return nil end
  
  local tempObj = core_vehicles.spawnNewVehicle(matConfig.model, {
    config = matConfig.config,
    pos = vec3(0, 0, -1000),
    rot = quatFromDir(vec3(0,1,0)),
    autoEnterVehicle = false
  })
  
  if not tempObj then return nil end
  
  local objId = tempObj:getID()
  local obj = be:getObjectByID(objId)
  if not obj then
    tempObj:delete()
    return nil
  end
  
  local aabb = nil
  if obj.getSpawnLocalAABB then
    local spawnAABB = obj:getSpawnLocalAABB()
    if spawnAABB then
      local extents = spawnAABB:getExtents()
      if extents then
        aabb = {
          xMin = -extents.x,
          xMax = extents.x,
          yMin = -extents.y,
          yMax = extents.y,
          zMin = -extents.z,
          zMax = extents.z
        }
      end
    end
  end
  
  if not aabb then
    obj:delete()
    local defaultBbox = { width = 3, length = 3, height = 2, maxDim = 3 }
    M.cachedBoundingBoxes[materialType] = defaultBbox
    return defaultBbox
  end
  
  local width = math.max(math.abs(aabb.xMax - aabb.xMin), math.abs(aabb.yMax - aabb.yMin))
  local length = math.min(math.abs(aabb.xMax - aabb.xMin), math.abs(aabb.yMax - aabb.yMin))
  local height = math.abs(aabb.zMax - aabb.zMin)
  
  obj:delete()
  
  local bbox = { width = width, length = length, height = height, maxDim = math.max(width, length) }
  M.cachedBoundingBoxes[materialType] = bbox
  return bbox
end

function M.generateGridPositions(basePos, zone, maxCount, gridSpacing, minRoadDist, avoidPos, minPlayerDist)
  minRoadDist = minRoadDist or 5
  gridSpacing = gridSpacing or 3
  maxCount = maxCount or 50
  minPlayerDist = minPlayerDist or 10
  
  if not zone or not zone.aabb or zone.aabb.invalid then return {} end
  if not map or not map.findClosestRoad then return {} end
  
  local positions = {}
  local gridSize = math.ceil(math.sqrt(maxCount))
  local halfSize = (gridSize - 1) * gridSpacing * 0.5
  
  local dir = vec3(0, 1, 0)
  if basePos and zone.loading and zone.loading.center then
    local centerDir = vec3(zone.loading.center) - basePos
    centerDir.z = 0
    if centerDir:length() > 0.1 then
      dir = centerDir:normalized()
    end
  end
  
  local right = vec3(-dir.y, dir.x, 0)
  
  for row = 0, gridSize - 1 do
    for col = 0, gridSize - 1 do
      if #positions >= maxCount then break end
      
      local offsetX = (col - (gridSize - 1) * 0.5) * gridSpacing
      local offsetY = (row - (gridSize - 1) * 0.5) * gridSpacing
      
      local gridPos = basePos + (right * offsetX) + (dir * offsetY)
      gridPos.z = core_terrain.getTerrainHeight(gridPos)
      
      if zone:containsPoint2D(gridPos) then
        local _, _, roadDist = map.findClosestRoad(gridPos)
        if roadDist and roadDist > minRoadDist then
          local validPos = true
          if avoidPos then
            local distToPlayer = (gridPos - avoidPos):length()
            if distToPlayer < (minPlayerDist or 10) then
              validPos = false
            end
          end
          if validPos then
            table.insert(positions, gridPos)
          end
        end
      end
    end
    if #positions >= maxCount then break end
  end
  
  return positions
end

function M.managePropCapacity()
  while #M.propQueue > Config.settings.maxProps do
    local oldEntry = table.remove(M.propQueue, 1)
    if oldEntry and oldEntry.id then
      M.propQueueById[oldEntry.id] = nil
      local obj = be:getObjectByID(oldEntry.id)
      if obj then obj:delete() end
    end
  end
end

local function getContractMaterialRequirements(contract)
  if not contract or contract.unitType ~= "item" or not contract.materialTypeName then
    return {}
  end
  
  if contract.materialRequirements and next(contract.materialRequirements) then
    return contract.materialRequirements
  end
  
  local Config = extensions.gameplay_loading_config
  local materialsOfType = {}
  if Config and Config.materials then
    for matKey, matConfig in pairs(Config.materials) do
      if matConfig.typeName == contract.materialTypeName then
        table.insert(materialsOfType, { key = matKey, config = matConfig })
      end
    end
  end
  
  if #materialsOfType <= 1 then
    if #materialsOfType == 1 then
      return { [materialsOfType[1].key] = contract.requiredItems or 0 }
    end
    return {}
  end
  
  table.sort(materialsOfType, function(a, b)
    local aMass = (a.config.unitType == "mass" and a.config.massPerProp) or 0
    local bMass = (b.config.unitType == "mass" and b.config.massPerProp) or 0
    return aMass < bMass
  end)
  
  local totalRequired = contract.requiredItems or 0
  local breakdown = {}
  
  if totalRequired <= 0 then
    return {}
  end
  
  if #materialsOfType == 2 and totalRequired == 2 then
    breakdown[materialsOfType[1].key] = 1
    breakdown[materialsOfType[2].key] = 1
  elseif #materialsOfType == 2 then
    local smaller = materialsOfType[1]
    local larger = materialsOfType[2]
    local smallerCount = math.max(1, math.floor(totalRequired / 2))
    breakdown[smaller.key] = smallerCount
    breakdown[larger.key] = totalRequired - smallerCount
  else
    local remaining = totalRequired
    for i, mat in ipairs(materialsOfType) do
      if i == #materialsOfType then
        breakdown[mat.key] = remaining
      else
        local count = math.max(1, math.floor(totalRequired / #materialsOfType))
        breakdown[mat.key] = count
        remaining = remaining - count
      end
    end
  end
  
  return breakdown
end

function M.deleteDamagedItem(propId)
  for i = #M.propQueue, 1, -1 do
    if M.propQueue[i].id == propId then
      local entry = M.propQueue[i]
      M.propQueueById[propId] = nil
      M.itemInitialState[propId] = nil
      M.itemDamageState[propId] = nil
      if M.jobObjects.itemDamage and M.jobObjects.itemDamage[propId] then
        M.jobObjects.itemDamage[propId] = nil
      end
      
      
      local obj = be:getObjectByID(propId)
      if obj then obj:delete() end
      table.remove(M.propQueue, i)
      return true
    end
  end
  return false
end

function M.repairAndRespawnDamagedItem(propId, zonesMod, contractsMod)
  local entry = M.propQueueById[propId]
  if not entry then return false end
  
  local group = M.jobObjects.activeGroup
  if not group then return false end
  
  if not M.pendingRespawns then
    M.pendingRespawns = {}
  end
  
  local respawnId = #M.pendingRespawns + 1
  M.pendingRespawns[respawnId] = {
    propId = propId,
    materialType = entry.materialType,
    spawnTime = os.clock() + 15.0,
    group = group
  }
  
  return true
end

function M.processPendingRespawns(dt, zonesMod, contractsMod)
  if not M.jobObjects.activeGroup then return end
  
  if not M.pendingRespawns then
    M.pendingRespawns = {}
  end
  
  local currentTime = os.clock()
  local playerVeh = be:getPlayerVehicle(0)
  local playerPos = playerVeh and playerVeh:getPosition() or nil
  
  for i = #M.pendingRespawns, 1, -1 do
    local respawn = M.pendingRespawns[i]
    if respawn.spawnTime <= currentTime then
      local group = respawn.group
      if not group or group ~= M.jobObjects.activeGroup then
        table.remove(M.pendingRespawns, i)
      else
        local cache = zonesMod.ensureGroupCache(group, contractsMod.getCurrentGameHour)
        if not cache or not cache.materialStocks then
          table.remove(M.pendingRespawns, i)
        else
          local stock = cache.materialStocks[respawn.materialType]
          if respawn.propId then
            M.deleteDamagedItem(respawn.propId)
          end
          
          if not stock or stock.current <= 0 then
            table.remove(M.pendingRespawns, i)
          else
            local zone = group.loading
            if not zone then
              table.remove(M.pendingRespawns, i)
            else
              local basePos = cache.offRoadCentroid
              if not basePos then
                basePos = zonesMod.findOffRoadCentroid(zone, 5, 1000)
                if basePos then cache.offRoadCentroid = basePos end
              end
              if not basePos then
                table.remove(M.pendingRespawns, i)
              else
                basePos = basePos + vec3(0, 0, 0.2)
                
                local spawnPos = nil
                local designatedSpawnLocs = group.materialSpawnLocations or {}
                
                if #designatedSpawnLocs > 0 then
                  local spawnLocIdx = math.random(1, #designatedSpawnLocs)
                  local designatedLoc = designatedSpawnLocs[spawnLocIdx]
                  spawnPos = vec3(designatedLoc.pos)
                else
                  local bbox = M.getMaterialBoundingBox(respawn.materialType)
                  local maxBoundingBox = bbox and bbox.maxDim or 3
                  local gridSpacing = math.max(maxBoundingBox * 0.8, 0.5)
                  
                  local gridPositions = M.generateGridPositions(basePos, zone, 50, gridSpacing, 6, playerPos, 10)
                  
                  if #gridPositions > 0 then
                    local minDistToExisting = gridSpacing * 0.5
                    for _, gridPos in ipairs(gridPositions) do
                      local tooClose = false
                      for _, existingEntry in ipairs(M.propQueue) do
                        if existingEntry.id ~= respawn.propId then
                          local existingObj = be:getObjectByID(existingEntry.id)
                          if existingObj then
                            local existingPos = existingObj:getPosition()
                            local dist = (gridPos - existingPos):length()
                            if dist < minDistToExisting then
                              tooClose = true
                              break
                            end
                          end
                        end
                      end
                      if not tooClose then
                        spawnPos = gridPos
                        break
                      end
                    end
                    
                    if not spawnPos and #gridPositions > 0 then
                      spawnPos = gridPositions[1]
                    end
                  end
                  
                  if not spawnPos then
                    spawnPos = basePos
                  end
                end
                
                if respawn.propId then
                  M.deleteDamagedItem(respawn.propId)
                end
                
                local matConfig = M.getMaterialConfig(respawn.materialType)
                if matConfig and matConfig.model then
                  local spawnOptions = {
                    pos = spawnPos,
                    rot = quat(0, 0, 0, 1),
                    config = matConfig.config or "default",
                    autoEnterVehicle = false
                  }
                  
                  if #designatedSpawnLocs > 0 then
                    spawnOptions.cling = true
                  end
                  
                  local newObj = core_vehicles.spawnNewVehicle(matConfig.model, spawnOptions)
                  
                  if newObj then
                    local newId = newObj:getID()
                    local actualObj = be:getObjectByID(newId)
                    if actualObj then
                      local propMass = matConfig.unitType == "mass" and (matConfig.massPerProp or 41000) or 0
                      local entry = { 
                        id = newId, 
                        mass = propMass, 
                        materialType = respawn.materialType,
                        blockType = matConfig.unitType == "item" and matConfig.config or nil
                      }
                      table.insert(M.propQueue, entry)
                      M.propQueueById[newId] = entry
                      
                      if stock.current > 0 then
                        stock.current = stock.current - 1
                      end
                    end
                  end
                end
                
                table.remove(M.pendingRespawns, i)
              end
            end
          end
        end
      end
    end
  end
end

function M.respawnMassMaterials(contractsMod, zonesMod, deliveredMassKg)
  M.cleanupStalePropEntries()
  if not M.jobObjects.activeGroup or not M.jobObjects.activeGroup.loading then return end
  if not deliveredMassKg or deliveredMassKg <= 0 then return end
  
  local group = M.jobObjects.activeGroup
  local zone = group.loading
  
  local cache = zonesMod.ensureGroupCache(group, contractsMod.getCurrentGameHour)
  if not cache or not cache.materialStocks then return end
  
  local contract = contractsMod.ContractSystem.activeContract
  if not contract or not contract.materialTypeName then return end
  
  local contractTypeName = contract.materialTypeName
  local materialType = nil
  
  if group.materials then
    for _, matKey in ipairs(group.materials) do
      local matConfig = M.getMaterialConfig(matKey)
      if matConfig and matConfig.typeName == contractTypeName and matConfig.unitType == "mass" then
        materialType = matKey
        break
      end
    end
  elseif group.materialType then
    local matConfig = M.getMaterialConfig(group.materialType)
    if matConfig and matConfig.typeName == contractTypeName and matConfig.unitType == "mass" then
      materialType = group.materialType
    end
  end
  
  if not materialType then return end
  
  local matConfig = M.getMaterialConfig(materialType)
  if not matConfig then return end
  
  local stock = cache.materialStocks[materialType]
  if not stock then return end
  
  if stock.current <= 0 then
    return
  end
  
  local actualSpawnAmount = math.min(deliveredMassKg, stock.current)
  local actualSpawnAmountKg = actualSpawnAmount
  
  local massPerProp = matConfig.massPerProp or 41000
  local propsToSpawn = math.max(1, math.ceil(actualSpawnAmountKg / massPerProp))
  local massPerPropKg = massPerProp
  
  local designatedSpawnLocs = group.materialSpawnLocations or {}
  local useDesignatedSpawns = #designatedSpawnLocs > 0
  local designatedSpawnIdx = 0
  
  local actuallySpawned = 0
  local totalMassSpawned = 0
  
  for _ = 1, propsToSpawn do
    local spawnPos = nil
    
    if useDesignatedSpawns then
      designatedSpawnIdx = designatedSpawnIdx + 1
      local spawnLocIdx = ((designatedSpawnIdx - 1) % #designatedSpawnLocs) + 1
      local designatedLoc = designatedSpawnLocs[spawnLocIdx]
      spawnPos = vec3(designatedLoc.pos)
    else
      zonesMod.ensureGroupOffRoadCentroid(group, contractsMod.getCurrentGameHour)
      local basePos = cache.offRoadCentroid
      if not basePos then
        basePos = zonesMod.findOffRoadCentroid(zone, 5, 1000)
        if basePos then cache.offRoadCentroid = basePos end
      end
      if basePos then
        spawnPos = basePos + vec3(0, 0, 0.2)
      end
    end
    
    if not spawnPos then
      break
    end
    
    local spawnOptions = {
      config = matConfig.config,
      pos = spawnPos,
      rot = quatFromDir(vec3(0,1,0)),
      autoEnterVehicle = false
    }
    
    if useDesignatedSpawns then
      spawnOptions.cling = true
    end
    
    local obj = core_vehicles.spawnNewVehicle(matConfig.model, spawnOptions)
    if obj then
      local propId = obj:getID()
      local actualObj = be:getObjectByID(propId)
      if actualObj then
        local entry = { 
          id = propId, 
          mass = massPerPropKg, 
          materialType = materialType,
          blockType = nil
        }
        table.insert(M.propQueue, entry)
        M.propQueueById[propId] = entry
        actuallySpawned = actuallySpawned + 1
        totalMassSpawned = totalMassSpawned + massPerPropKg
        M.managePropCapacity()
      else
        if obj then obj:delete() end
      end
    end
  end
  
  if actuallySpawned > 0 then
    stock.current = stock.current - actualSpawnAmount
  end
end

function M.spawnJobMaterials(contractsMod, zonesMod, playerPos)
  M.cleanupStalePropEntries()
  if not M.jobObjects.activeGroup or not M.jobObjects.activeGroup.loading then return end

  local group = M.jobObjects.activeGroup
  local zone = group.loading
  
  local cache = zonesMod.ensureGroupCache(group, contractsMod.getCurrentGameHour)
  if not cache or not cache.materialStocks then return end
  
  zonesMod.ensureGroupOffRoadCentroid(group, contractsMod.getCurrentGameHour)
  
  local contract = contractsMod.ContractSystem.activeContract
  if not contract or not contract.materialTypeName then
    return
  end
  
  local contractTypeName = contract.materialTypeName
  local compatibleMaterials = {}
  
  if group.materials then
    for _, matKey in ipairs(group.materials) do
      local matConfig = M.getMaterialConfig(matKey)
      if matConfig and matConfig.typeName == contractTypeName then
        table.insert(compatibleMaterials, matKey)
      end
    end
  elseif group.materialType then
    local matConfig = M.getMaterialConfig(group.materialType)
    if matConfig and matConfig.typeName == contractTypeName then
      table.insert(compatibleMaterials, group.materialType)
    end
  end
  
  if #compatibleMaterials == 0 then
    return
  end
  
  if not cache.spawnedPropCounts then
    cache.spawnedPropCounts = {}
  end
  
  local materialRequirements = {}
  if contract.unitType == "item" then
    materialRequirements = getContractMaterialRequirements(contract)
  else
    for _, matKey in ipairs(compatibleMaterials) do
      materialRequirements[matKey] = math.huge
    end
  end
  
  local basePos = cache.offRoadCentroid or nil
  if not basePos then
    basePos = zonesMod.findOffRoadCentroid(zone, 5, 1000)
    if cache then cache.offRoadCentroid = basePos end
  end
  if not basePos then return end
  basePos = basePos + vec3(0,0,0.2)

  local totalPropsSpawned = 0
  local globalMaxProps = Config.settings.maxProps or 6
  
  local maxBoundingBox = 0
  for _, materialType in ipairs(compatibleMaterials) do
    local matConfig = M.getMaterialConfig(materialType)
    if matConfig then
      local bbox = M.getMaterialBoundingBox(materialType)
      if bbox and bbox.maxDim > maxBoundingBox then
        maxBoundingBox = bbox.maxDim
      end
    end
  end
  
  local gridSpacing = math.max(maxBoundingBox * 0.8, 0.5)
  local maxGridSize = globalMaxProps + 10
  local designatedSpawnLocs = group.materialSpawnLocations or {}
  local useDesignatedSpawns = #designatedSpawnLocs > 0
  local gridPositions = {}
  local gridPosIdx = 1
  if not useDesignatedSpawns then
    gridPositions = M.generateGridPositions(basePos, zone, maxGridSize, gridSpacing, 6, playerPos, 10)
  end
  local designatedSpawnIdx = 0
  
  local loadedPropIds = {}
  local loadedSet = {}
  if M.jobObjects.truckID then
    loadedPropIds = M.getLoadedPropIdsInTruck(0.1) or {}
    for _, id in ipairs(loadedPropIds) do
      loadedSet[id] = true
    end
  end
  
  local totalCurrentlySpawned = 0
  for _, entry in ipairs(M.propQueue) do
    if not loadedSet[entry.id] then
      totalCurrentlySpawned = totalCurrentlySpawned + 1
    end
  end
  local globalMaxAllowed = math.max(0, globalMaxProps - totalCurrentlySpawned)
  
  for _, materialType in ipairs(compatibleMaterials) do
    local matConfig = M.getMaterialConfig(materialType)
    if matConfig then
      local stock = cache.materialStocks[materialType]
      if stock and stock.current > 0 then
        local currentlyAlive = 0
        local zoneLoadingArea = zone
        for _, entry in ipairs(M.propQueue) do
          if entry.materialType == materialType and not loadedSet[entry.id] then
            local propObj = be:getObjectByID(entry.id)
            if propObj and zoneLoadingArea and zoneLoadingArea:containsPoint2D(propObj:getPosition()) then
              currentlyAlive = currentlyAlive + 1
            end
          end
        end
        
        local propsToSpawn = 0
        local isMassContract = contract.unitType ~= "item"
        
        if isMassContract then
          if contractsMod.checkContractCompletion and contractsMod.checkContractCompletion() then
            return
          end
          
          local massPerProp = matConfig.massPerProp or 41000
          local maxPropsFromStock = math.floor(stock.current / massPerProp)
          local maxSpawned = matConfig.maxSpawned or math.huge
          local materialMaxAllowed = math.max(0, maxSpawned - currentlyAlive)
          propsToSpawn = math.min(maxPropsFromStock, materialMaxAllowed, globalMaxAllowed)
          
          if propsToSpawn > 0 then
          end
        else
          local required = materialRequirements[materialType] or 0
          local delivered = 0
          if contractsMod.ContractSystem.contractProgress and contractsMod.ContractSystem.contractProgress.deliveredItemsByMaterial then
            delivered = contractsMod.ContractSystem.contractProgress.deliveredItemsByMaterial[materialType] or 0
          end
          
          local loadedCount = 0
          for _, entry in ipairs(M.propQueue) do
            if entry.materialType == materialType and loadedSet[entry.id] then
              loadedCount = loadedCount + 1
            end
          end
          
          local totalNeededForContract = required - delivered
          local totalStillNeeded = math.max(0, totalNeededForContract - currentlyAlive - loadedCount)
          
          if totalStillNeeded > 0 then
            local maxSpawned = matConfig.maxSpawned or math.huge
            local materialMaxAllowed = math.max(0, maxSpawned - currentlyAlive)
            propsToSpawn = math.min(totalStillNeeded, stock.current, materialMaxAllowed, globalMaxAllowed)
            
            if propsToSpawn > 0 then
            end
          end
        end
        
        if propsToSpawn > 0 then
          local actuallySpawned = 0
          local totalMassSpawned = 0
          for _ = 1, propsToSpawn do
            local spawnPos
            if useDesignatedSpawns then
              if #designatedSpawnLocs > 0 then
                designatedSpawnIdx = designatedSpawnIdx + 1
                local spawnLocIdx = ((designatedSpawnIdx - 1) % #designatedSpawnLocs) + 1
                local designatedLoc = designatedSpawnLocs[spawnLocIdx]
                spawnPos = vec3(designatedLoc.pos)
              else
                break
              end
            else
              if gridPosIdx > #gridPositions then
                break
              end
              spawnPos = gridPositions[gridPosIdx]
              gridPosIdx = gridPosIdx + 1
            end
            
            if not spawnPos then break end
            
            local spawnOptions = {
              config = matConfig.config,
              pos = spawnPos,
              rot = quatFromDir(vec3(0,1,0)),
              autoEnterVehicle = false
            }
            
            if useDesignatedSpawns then
              spawnOptions.cling = true
            end
            
            local obj = core_vehicles.spawnNewVehicle(matConfig.model, spawnOptions)
            if obj then
              local propId = obj:getID()
              local actualObj = be:getObjectByID(propId)
              if actualObj then
                local propMass = matConfig.unitType == "mass" and (matConfig.massPerProp or 41000) or 0
                local entry = { 
                  id = propId, 
                  mass = propMass, 
                  materialType = materialType,
                  blockType = matConfig.unitType == "item" and matConfig.config or nil
                }
                table.insert(M.propQueue, entry)
                M.propQueueById[propId] = entry
                totalPropsSpawned = totalPropsSpawned + 1
                globalMaxAllowed = globalMaxAllowed - 1
                actuallySpawned = actuallySpawned + 1
                totalMassSpawned = totalMassSpawned + propMass
                
                if isMassContract then
                  stock.current = stock.current - propMass
                else
                  stock.current = stock.current - 1
                end
                
                if not cache.spawnedPropCounts[materialType] then
                  cache.spawnedPropCounts[materialType] = 0
                end
                cache.spawnedPropCounts[materialType] = cache.spawnedPropCounts[materialType] + 1
                M.managePropCapacity()
              else
                if obj then obj:delete() end
              end
            end
          end
          
          if actuallySpawned ~= propsToSpawn then
          end
          if isMassContract and actuallySpawned > 0 then
          end
        end
      end
    end
  end
  
  if totalPropsSpawned > 0 then
  end
end

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
    local Zones = extensions.gameplay_loading_zones
    local Contracts = extensions.gameplay_loading_contracts
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
    local Zones = extensions.gameplay_loading_zones
    local Contracts = extensions.gameplay_loading_contracts
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

local function setupTruckAI(truck)
  if not truck then return end
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

  local pos, rot = M.calculateSpawnTransformForLocation(vec3(group.spawn.pos), targetPos)
  local truck = core_vehicles.spawnNewVehicle(truckModel, { pos = pos, rot = rot, config = truckConfig, autoEnterVehicle = false })
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
  M.truckNudging = false
  M.truckNudgeModeSet = false
  M.truckRouteStartTime = os.clock()
  truck:queueLuaCommand('if not driver then extensions.load("driver") end')
  truck:queueLuaCommand("input.event('parkingbrake', 0, 1)")
  setupTruckAI(truck)
  core_jobsystem.create(function(job)
    job.sleep(0.5)
    truck:queueLuaCommand("if ai.setAvoidCars then ai.setAvoidCars('off') end")
    job.sleep(0.1)
    truck:queueLuaCommand('driver.returnTargetPosition(' .. serialize(targetPos) .. ', false, "limit", true)')
  end)
end

function M.stopTruck(truckId)
  local truck = be:getObjectByID(truckId)
  if not truck then return end
  truck:queueLuaCommand("ai.setMode('stop')")
  truck:queueLuaCommand("input.event('parkingbrake', 1, 1)")
end

function M.nudgeTruckForward(truckId, throttle)
  local truck = be:getObjectByID(truckId)
  if not truck then return end
  throttle = throttle or 0.3
  if not M.truckNudgeModeSet then
    truck:queueLuaCommand("ai.setMode('manual')")
    M.truckNudgeModeSet = true
  end
  truck:queueLuaCommand("input.event('parkingbrake', 0, 1)")
  truck:queueLuaCommand("input.event('throttle', " .. throttle .. ", 1)")
end

function M.nudgeTruckWithControl(truckId, throttle, brake, steering)
  local truck = be:getObjectByID(truckId)
  if not truck then return end
  throttle = throttle or 0
  brake = brake or 0
  steering = steering or 0
  if not M.truckNudgeModeSet then
    truck:queueLuaCommand("ai.setMode('manual')")
    M.truckNudgeModeSet = true
  end
  truck:queueLuaCommand("input.event('parkingbrake', 0, 1)")
  truck:queueLuaCommand("input.event('throttle', " .. throttle .. ", 1)")
  truck:queueLuaCommand("input.event('brake', " .. brake .. ", 1)")
  truck:queueLuaCommand("input.event('steering', " .. steering .. ", 2)")
end

function M.stopNudging(truckId)
  local truck = be:getObjectByID(truckId)
  if not truck then return end
  M.truckNudgeModeSet = false
  M.truckNudging = false
  truck:queueLuaCommand("ai.setMode('stop')")
  truck:queueLuaCommand("input.event('throttle', 0, 1)")
  truck:queueLuaCommand("input.event('brake', 0, 1)")
  truck:queueLuaCommand("input.event('steering', 0, 2)")
  truck:queueLuaCommand("input.event('parkingbrake', 1, 1)")
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

function M.getTruckBedData(obj)
  if not obj then return nil end
  local truckId = obj:getID()
  if M.cachedBedData[truckId] then
    local cached = M.cachedBedData[truckId]
    local pos = obj:getPosition()
    local dir = obj:getDirectionVector():normalized()
    local up = obj:getDirectionVectorUp():normalized()
    local right = dir:cross(up):normalized()
    up = right:cross(dir):normalized()
    
    local offsetBack, offsetSide = cached.settings.offsetBack or 0, cached.settings.offsetSide or 0
    local bedCenterHeight = (cached.settings.floorHeight or 0) + ((cached.settings.loadHeight or 0) / 2)
    local bedCenter = pos - (dir * offsetBack) + (right * offsetSide) + (up * bedCenterHeight)
    
    cached.center = bedCenter
    cached.axisX = right
    cached.axisY = dir
    cached.axisZ = up
    return cached
  end
  
  local pos = obj:getPosition()
  local dir = obj:getDirectionVector():normalized()
  local up = obj:getDirectionVectorUp():normalized()
  local right = dir:cross(up):normalized()
  up = right:cross(dir):normalized()
  
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

  local offsetBack, offsetSide = bedSettings.offsetBack or 0, bedSettings.offsetSide or 0
  local bedCenterHeight = (bedSettings.floorHeight or 0) + ((bedSettings.loadHeight or 0) / 2)
  local bedCenter = pos - (dir * offsetBack) + (right * offsetSide) + (up * bedCenterHeight)
  
  local bedData = {
    center = bedCenter, axisX = right, axisY = dir, axisZ = up,
    halfWidth = (bedSettings.width or 1) / 2, halfLength = (bedSettings.length or 1) / 2,
    halfHeight = (bedSettings.loadHeight or 1) / 2, floorHeight = bedSettings.floorHeight or 0,
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

local function calculatePayloadForProps(propEntries, bedData, materialType, includeDamaged)
  local matConfig = M.getMaterialConfig(materialType)
  local defaultMass = 0
  if matConfig and matConfig.unitType == "mass" then
    defaultMass = matConfig.massPerProp or 41000
  end
  local nodeStep = Config.settings.payload and Config.settings.payload.nodeSamplingStep or 10
  
  local totalMass = 0
  for _, rockEntry in ipairs(propEntries) do
    if not includeDamaged and M.jobObjects.itemDamage and M.jobObjects.itemDamage[rockEntry.id] and M.jobObjects.itemDamage[rockEntry.id].isDamaged then
      -- Skip damaged items
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

function M.captureItemInitialState(objId)
  local obj = be:getObjectByID(objId)
  if not obj then return end
  M.itemInitialState[objId] = { nodeCount = obj:getNodeCount(), captureTime = os.clock(), captured = true }
  M.itemDamageState[objId] = { isDamaged = false, lastUpdate = 0 }
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
        if not damageCache or (os.clock() - damageCache.lastUpdate) > 0.5 then
          -- Dynamic damage detection from JSON
          local ignoreList = matConfig.damage and matConfig.damage.ignore or {}
          local threshold = matConfig.damage and matConfig.damage.damageThreshold or 0.01
          local ignoreStr = ""
          if #ignoreList > 0 then
            local patterns = {}
            for _, p in ipairs(ignoreList) do table.insert(patterns, string.format('"%s"', p:lower())) end
            ignoreStr = "local patterns = {" .. table.concat(patterns, ",") .. "} "
            ignoreStr = ignoreStr .. "for _, p in ipairs(patterns) do if string.find(string.lower(k), p) then shouldIgnore = true; break end end "
          end
          
          local luaCmd = string.format('obj:queueGameEngineLua("gameplay_loading.onItemDamageCallback(' .. rockEntry.id .. ', " .. tostring(beamstate and beamstate.getPartDamageData and (function() for k,v in pairs(beamstate.getPartDamageData()) do local shouldIgnore = false; %s if not shouldIgnore and v.damage > %f then return true end end return false end)()) .. ")")', ignoreStr, threshold)
          obj:queueLuaCommand(luaCmd)
        end
        
        local isDamaged = damageCache and damageCache.isDamaged or false
        local wasDamaged = M.jobObjects.itemDamage[rockEntry.id] and M.jobObjects.itemDamage[rockEntry.id].isDamaged or false
        local damagePercent = isDamaged and 1 or 0
        M.jobObjects.itemDamage[rockEntry.id] = { damage = damagePercent, isDamaged = isDamaged, brokenPieces = isDamaged and 1 or 0 }
        
        if isDamaged and not wasDamaged then
          local Contracts = gameplay_loading_contracts
          local Zones = gameplay_loading_zones
          if Contracts and Zones then
            M.repairAndRespawnDamagedItem(rockEntry.id, Zones, Contracts)
          end
          
          if matConfig.reputationLoss and matConfig.damage then
            local career = career_career
            if career and type(career.isActive) == "function" and career.isActive() then
              local activeGroup = M.jobObjects.activeGroup
              if activeGroup and activeGroup.associatedOrganization then
                local orgId = activeGroup.associatedOrganization
                local paymentModule = career_modules_payment
                if paymentModule and type(paymentModule.reward) == "function" then
                  local repKey = orgId .. "Reputation"
                  paymentModule.reward({
                    [repKey] = { amount = -matConfig.reputationLoss }
                  }, { label = string.format("Damaged %s", matConfig.name or materialType), tags = {"gameplay", "loading", "reputation"} })
                end
              end
            end
          end
        end
        
        if not M.propQueueById[rockEntry.id] then
          checkedCount = checkedCount - 1
        else

          totalDamage = totalDamage + damagePercent
          if isDamaged then damagedCount = damagedCount + 1 end
        end
      end
    end
  end
  
  if checkedCount > 0 then
    M.jobObjects.totalItemDamagePercent = (totalDamage / checkedCount) * 100
    M.jobObjects.anyItemDamaged = damagedCount > 0
  else
    M.jobObjects.totalItemDamagePercent, M.jobObjects.anyItemDamaged = 0, false
  end
end

function M.getLoadedPropIdsInTruck(minRatio)
  minRatio = minRatio or (Config.settings.payload and Config.settings.payload.minLoadRatio or 0.25)
  if #M.propQueue == 0 or not M.jobObjects.truckID then return {} end
  local truck = be:getObjectByID(M.jobObjects.truckID)
  if not truck then return {} end
  local bedData = M.getTruckBedData(truck)
  if not bedData then return {} end
  local nodeStep = Config.settings.payload and Config.settings.payload.nodeSamplingStep or 10
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
  local nodeStep = Config.settings.payload and Config.settings.payload.nodeSamplingStep or 10
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

function M.consumeZoneStock(group, deliveredPropIds, zonesMod, contractsMod)
  if not group then return end
  local cache = zonesMod.ensureGroupCache(group, contractsMod.getCurrentGameHour)
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

function M.returnPropsToStock(propIds, zonesMod, contractsMod)
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
  
  local cache = zonesMod.ensureGroupCache(M.jobObjects.activeGroup, contractsMod.getCurrentGameHour)
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

function M.despawnPropIds(propIds, zonesMod, contractsMod, skipStockConsumption)
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
    local cache = zonesMod.ensureGroupCache(M.jobObjects.activeGroup, contractsMod.getCurrentGameHour)
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

function M.handleTruckMovement(dt, destPos, contractsMod)
  if not M.jobObjects.truckID or not destPos then return end
  local truck = be:getObjectByID(M.jobObjects.truckID)
  if not truck then
    local zoneTag = M.jobObjects.activeGroup and M.jobObjects.activeGroup.secondaryTag
    local contractsConfig = zoneTag and contractsMod.getContractsConfig and contractsMod.getContractsConfig(zoneTag) or {}
    local crashPenalty = contractsConfig.crashPenalty or 0
    contractsMod.failContract(crashPenalty, "Truck destroyed! Contract failed.", "warning", M.cleanupJob)
    return
  end
  
  local arrivalDist = Config.settings.truck and Config.settings.truck.arrivalDistanceThreshold or 10.0
  local truckPos = truck:getPosition()
  if (truckPos - destPos):length() < arrivalDist then
    M.truckStoppedTimer, M.truckLastPosition = 0, nil
    M.truckDamage = 0
    M.damageCheckQueued = false
    M.teleportQueued = false
    return true
  end
  
  M.deliveryTimer = M.deliveryTimer + dt
  
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
      M.truckStoppedTimer = M.truckStoppedTimer + dt
      if M.truckStoppedTimer >= 10.0 then
        if not M.damageCheckQueued then
          truck:queueLuaCommand('if beamstate and beamstate.damage then obj:queueGameEngineLua("gameplay_loading_manager.onTruckDamageCallback(" .. tostring(beamstate.damage) .. ")") end')
          M.damageCheckQueued = true
        end
        if M.truckDamage and M.truckDamage > 100000 then
          return "damaged", M.deliveryTimer
        end
      end
      if M.truckStoppedTimer >= 30.0 then
        if not M.teleportQueued and (not M.truckDamage or M.truckDamage <= 100000) then
          local map = map
          if map and map.findClosestRoad and map.getMap then
            local roadName, nodeIdx, roadDist = map.findClosestRoad(truckPos)
            if roadName and nodeIdx then
              local mapData = map.getMap()
              if mapData and mapData.nodes and mapData.nodes[nodeIdx] then
                local node = mapData.nodes[nodeIdx]
                if node and node.pos then
                  local roadNodePos = vec3(node.pos)
                  local truckRot = truck:getRotation()
                  spawn.safeTeleport(truck, roadNodePos, truckRot, nil, nil, nil, true)
                  M.truckStoppedTimer = 0
                  M.truckLastPosition = roadNodePos
                  M.teleportQueued = true
                  M.truckNudging = false
                  M.truckRouteStartTime = os.clock()
                end
              end
            end
          end
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

function M.beginActiveContractTrip(contractsMod, zonesMod, uiMod)
  local contract = contractsMod.ContractSystem.activeContract
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
    M.spawnJobMaterials(contractsMod, zonesMod)
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

M.onExtensionLoaded = function()
end
M.loadingConfigLoaded = function()
  Config = gameplay_loading_config
end

return M

