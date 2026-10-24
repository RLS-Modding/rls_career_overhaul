-- Quarry prop placement, respawn and material spawning.
-- Read transforms, capacity, damage repair, pending respawns, mass respawn and first zone fill.
return function(Config, M)
  local quarrySettings = require("overhaul/jobs/quarry/settings")
  local props = {}

  local function nextSpawnRoadNode(path, spawnPosVec, spawnRoadName, targetRoadName, spawnNodeIdx, targetNodeIdx, mapData)
    local nextNodeIdx
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
    return nextNodeIdx
  end

  local function applySpawnRoadDirection(nextNodeIdx, mapData, spawnPosVec, dir)
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
    return dir
  end

  function props.calculateSpawnTransformForLocation(spawnPos, targetPos)
    local dir = vec3(0, 1, 0)
    if targetPos then
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
          nextNodeIdx = nextSpawnRoadNode(path, spawnPosVec, spawnRoadName, targetRoadName, spawnNodeIdx, targetNodeIdx, mapData)
          dir = applySpawnRoadDirection(nextNodeIdx, mapData, spawnPosVec, dir)
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
    normal = map.surfaceNormal(spawnPos, 1)
    if dir:length() == 0 then dir = vec3(0,1,0) end
    local rotation = quatFromDir(dir, normal)
    return spawnPos, rotation
  end

  function props.getMaterialConfig(materialType)
    if M.cachedMaterialConfigs[materialType] then
      return M.cachedMaterialConfigs[materialType]
    end
    local matConfig = Config.materials and Config.materials[materialType]
    if matConfig then
      M.cachedMaterialConfigs[materialType] = matConfig
    end
    return matConfig
  end

  function props.getMaterialBoundingBox(materialType)
    if M.cachedBoundingBoxes[materialType] then
      return M.cachedBoundingBoxes[materialType]
    end
    local matConfig = M.getMaterialConfig(materialType)
    if not matConfig then return nil end
    if matConfig.boundingBox then return matConfig.boundingBox end
    local probe = Config.runtime and Config.runtime.probeSpawn
    if not probe or type(probe.pos) ~= "table" or #probe.pos ~= 3 or type(probe.rot) ~= "table" or #probe.rot ~= 4 then
      log("W", "quarry", "Material measurement disabled: missing overhaul/quarry.json probeSpawn")
      return nil
    end
    local tempObj = core_vehicles.spawnNewVehicle(matConfig.model, {
      config = matConfig.config,
      pos = vec3(probe.pos),
      rot = quat(probe.rot),
      autoEnterVehicle = false
    })
    if not tempObj then return nil end
    tempObj:setActive(0)
    if tempObj.setHidden then tempObj:setHidden(true) end
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

  local function appendValidGridPosition(positions, gridPos, zone, minRoadDist, avoidPos, minPlayerDist)
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

  function props.generateGridPositions(basePos, zone, maxCount, gridSpacing, minRoadDist, avoidPos, minPlayerDist)
    minRoadDist = minRoadDist or 5
    gridSpacing = gridSpacing or 3
    maxCount = maxCount or 50
    minPlayerDist = minPlayerDist or 10
    if not zone or not zone.aabb or zone.aabb.invalid then return {} end
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
        appendValidGridPosition(positions, gridPos, zone, minRoadDist, avoidPos, minPlayerDist)
      end
      if #positions >= maxCount then break end
    end
    return positions
  end

  function props.managePropCapacity()
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
    local Config = extensions.overhaul_jobs_quarry_config
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

  function props.deleteDamagedItem(propId)
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

  function props.repairAndRespawnDamagedItem(propId, zonesMod, contractsMod)
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

  local OFFROAD_CENTROID_SEARCH_STEP_M, OFFROAD_CENTROID_SEARCH_RANGE_M = 5, 1000
  local SPAWN_DROP_HEIGHT_M = 0.2 -- spawn slightly above the ground so the prop settles instead of clipping
  local RESPAWN_DEFAULT_MATERIAL_SIZE_M = 3 -- largest dimension assumed when the material has no bounding box
  local MIN_GRID_SPACING_M = 0.5
  local GRID_SPACING_PER_SIZE = 0.8 -- grid cell size as a share of the material's largest dimension
  local RESPAWN_CELL_CLEARANCE_PER_SPACING = 0.5 -- a cell is taken when an existing prop is closer than this share of the spacing
  local RESPAWN_GRID_MAX_POSITIONS = 50
  local GRID_ROAD_CLEARANCE_M = 6
  local GRID_PLAYER_CLEARANCE_M = 10
  local DEFAULT_MASS_PROP_KG = 41000

  local function getRespawnBasePosition(cache, zone, zonesMod)
    local basePos = cache.offRoadCentroid
    if not basePos then
      basePos = zonesMod.findOffRoadCentroid(zone, OFFROAD_CENTROID_SEARCH_STEP_M, OFFROAD_CENTROID_SEARCH_RANGE_M)
      if basePos then cache.offRoadCentroid = basePos end
    end
    return basePos
  end

  -- True when a queued prop other than `replacedPropId` sits closer than `minDistance` to `cellPos`.
  local function isGridCellTaken(cellPos, replacedPropId, minDistance)
    for _, existingEntry in ipairs(M.propQueue) do
      if existingEntry.id ~= replacedPropId then
        local existingObj = be:getObjectByID(existingEntry.id)
        if existingObj and (cellPos - existingObj:getPosition()):length() < minDistance then
          return true
        end
      end
    end
    return false
  end

  -- First free cell of a grid around basePos, else the first cell. Nil when the zone yields no cells.
  local function pickGridSpawnPosition(respawn, basePos, zone, playerPos)
    local bbox = M.getMaterialBoundingBox(respawn.materialType)
    local materialSize = bbox and bbox.maxDim or RESPAWN_DEFAULT_MATERIAL_SIZE_M
    local gridSpacing = math.max(materialSize * GRID_SPACING_PER_SIZE, MIN_GRID_SPACING_M)
    local gridPositions = M.generateGridPositions(basePos, zone, RESPAWN_GRID_MAX_POSITIONS, gridSpacing,
      GRID_ROAD_CLEARANCE_M, playerPos, GRID_PLAYER_CLEARANCE_M)
    if #gridPositions == 0 then return nil end
    local minDistToExisting = gridSpacing * RESPAWN_CELL_CLEARANCE_PER_SPACING
    for _, gridPos in ipairs(gridPositions) do
      if not isGridCellTaken(gridPos, respawn.propId, minDistToExisting) then
        return gridPos
      end
    end
    return gridPositions[1]
  end

  -- Queues the replacement prop for a successful spawn. True when it exists in the world.
  local function spawnReplacementProp(respawn, matConfig, spawnPos, clingToGround)
    local spawnOptions = {
      pos = spawnPos,
      rot = quat(0, 0, 0, 1),
      config = quarrySettings.respawnConfig(matConfig),
      autoEnterVehicle = false
    }
    if clingToGround then
      spawnOptions.cling = true
    end
    local newObj = core_vehicles.spawnNewVehicle(matConfig.model, spawnOptions)
    if not newObj then return false end
    local newId = newObj:getID()
    if not be:getObjectByID(newId) then return false end
    local propMass = matConfig.unitType == "mass" and (matConfig.massPerProp or DEFAULT_MASS_PROP_KG) or 0
    local entry = {
      id = newId,
      mass = propMass,
      materialType = respawn.materialType,
      blockType = matConfig.unitType == "item" and matConfig.config or nil
    }
    table.insert(M.propQueue, entry)
    M.propQueueById[newId] = entry
    return true
  end

  -- Replaces a destroyed prop with a fresh one while the zone still has stock. The caller drops the
  local function runRespawn(respawn, zonesMod, contractsMod, playerPos)
    local group = respawn.group
    if not group or group ~= M.jobObjects.activeGroup then return end
    local cache = zonesMod.ensureGroupCache(group, contractsMod.getCurrentGameHour)
    if not cache or not cache.materialStocks then return end
    local stock = cache.materialStocks[respawn.materialType]
    if respawn.propId then
      M.deleteDamagedItem(respawn.propId)
    end
    if not stock or stock.current <= 0 then return end
    local zone = group.loading
    if not zone then return end
    local basePos = getRespawnBasePosition(cache, zone, zonesMod)
    if not basePos then return end
    basePos = basePos + vec3(0, 0, SPAWN_DROP_HEIGHT_M)
    local designatedSpawnLocs = group.materialSpawnLocations or {}
    local hasDesignatedSpots = #designatedSpawnLocs > 0
    local spawnPos
    if hasDesignatedSpots then
      spawnPos = vec3(designatedSpawnLocs[math.random(1, #designatedSpawnLocs)].pos)
    else
      spawnPos = pickGridSpawnPosition(respawn, basePos, zone, playerPos) or basePos
    end
    if respawn.propId then
      M.deleteDamagedItem(respawn.propId)
    end
    local matConfig = M.getMaterialConfig(respawn.materialType)
    if not (matConfig and matConfig.model) then return end
    if spawnReplacementProp(respawn, matConfig, spawnPos, hasDesignatedSpots) and stock.current > 0 then
      stock.current = stock.current - 1
    end
  end

  function props.processPendingRespawns(dt, zonesMod, contractsMod)
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
        runRespawn(respawn, zonesMod, contractsMod, playerPos)
        table.remove(M.pendingRespawns, i)
      end
    end
  end

  local function massContractMaterial(contract, group)
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
    return materialType
  end

  local function spawnMassReplacementProps(group, zone, zonesMod, contractsMod, cache, propsToSpawn, matConfig, massPerPropKg, materialType)
    local designatedSpawnLocs = group.materialSpawnLocations or {}
    local useDesignatedSpawns = #designatedSpawnLocs > 0
    local designatedSpawnIdx = 0
    local actuallySpawned = 0
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
    return actuallySpawned
  end

  function props.respawnMassMaterials(contractsMod, zonesMod, deliveredMassKg)
    M.cleanupStalePropEntries()
    if not M.jobObjects.activeGroup or not M.jobObjects.activeGroup.loading then return end
    if not deliveredMassKg or deliveredMassKg <= 0 then return end
    local group = M.jobObjects.activeGroup
    local zone = group.loading
    local cache = zonesMod.ensureGroupCache(group, contractsMod.getCurrentGameHour)
    if not cache or not cache.materialStocks then return end
    local contract = contractsMod.ContractSystem.activeContract
    if not contract or not contract.materialTypeName then return end
    local materialType = massContractMaterial(contract, group)
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
    local actuallySpawned = spawnMassReplacementProps(group, zone, zonesMod, contractsMod, cache, propsToSpawn, matConfig, massPerPropKg, materialType)
    if actuallySpawned > 0 then
      stock.current = stock.current - actualSpawnAmount
    end
  end

  local SPAWN_GRID_SPARE_CELLS = 10 -- grid cells generated beyond the prop cap
  local IN_TRUCK_MIN_RATIO = 0.1 -- share of a prop that must be on the bed for it to count as loaded

  local function findCompatibleMaterials(group, contractTypeName)
    local compatible = {}
    local candidates = group.materials or (group.materialType and {group.materialType}) or {}
    for _, matKey in ipairs(candidates) do
      local matConfig = M.getMaterialConfig(matKey)
      if matConfig and matConfig.typeName == contractTypeName then
        table.insert(compatible, matKey)
      end
    end
    return compatible
  end

  local function largestMaterialSize(materials)
    local largest = 0
    for _, materialType in ipairs(materials) do
      local matConfig = M.getMaterialConfig(materialType)
      if matConfig then
        local bbox = M.getMaterialBoundingBox(materialType)
        if bbox and bbox.maxDim > largest then
          largest = bbox.maxDim
        end
      end
    end
    return largest
  end

  local function loadedPropSet()
    local loadedSet = {}
    if M.jobObjects.truckID then
      for _, id in ipairs(M.getLoadedPropIdsInTruck(IN_TRUCK_MIN_RATIO) or {}) do
        loadedSet[id] = true
      end
    end
    return loadedSet
  end

  local function countPropsOffTruck(loadedSet)
    local count = 0
    for _, entry in ipairs(M.propQueue) do
      if not loadedSet[entry.id] then
        count = count + 1
      end
    end
    return count
  end

  local function countAliveInZone(materialType, zone, loadedSet)
    local alive = 0
    for _, entry in ipairs(M.propQueue) do
      if entry.materialType == materialType and not loadedSet[entry.id] then
        local propObj = be:getObjectByID(entry.id)
        if propObj and zone:containsPoint2D(propObj:getPosition()) then
          alive = alive + 1
        end
      end
    end
    return alive
  end

  local function countLoadedOfMaterial(materialType, loadedSet)
    local count = 0
    for _, entry in ipairs(M.propQueue) do
      if entry.materialType == materialType and loadedSet[entry.id] then
        count = count + 1
      end
    end
    return count
  end

  local function materialSpawnRoom(matConfig, currentlyAlive)
    return math.max(0, (matConfig.maxSpawned or math.huge) - currentlyAlive)
  end

  -- Items the contract still needs of this material after deliveries, props standing and props on the truck.
  local function itemsStillNeeded(contractsMod, requirements, materialType, currentlyAlive, loadedSet)
    local required = requirements[materialType] or 0
    local progress = contractsMod.ContractSystem.contractProgress
    local delivered = progress and progress.deliveredItemsByMaterial and progress.deliveredItemsByMaterial[materialType] or 0
    return math.max(0, required - delivered - currentlyAlive - countLoadedOfMaterial(materialType, loadedSet))
  end

  local function newSpawnPositionSource(group, basePos, zone, playerPos, gridSpacing, maxGridSize)
    local designatedSpawnLocs = group.materialSpawnLocations or {}
    if #designatedSpawnLocs > 0 then
      local index = 0
      return function()
        index = index + 1
        return vec3(designatedSpawnLocs[((index - 1) % #designatedSpawnLocs) + 1].pos)
      end, true
    end
    local gridPositions = M.generateGridPositions(basePos, zone, maxGridSize, gridSpacing,
      GRID_ROAD_CLEARANCE_M, playerPos, GRID_PLAYER_CLEARANCE_M)
    local cellIndex = 0
    return function()
      cellIndex = cellIndex + 1
      return gridPositions[cellIndex]
    end, false
  end

  -- Spawns one prop and queues it. Returns its queue entry, or nil when the spawn failed.
  local function spawnMaterialProp(materialType, matConfig, spawnPos, clingToGround)
    local spawnOptions = {
      config = matConfig.config,
      pos = spawnPos,
      rot = quatFromDir(vec3(0,1,0)),
      autoEnterVehicle = false
    }
    if clingToGround then
      spawnOptions.cling = true
    end
    local obj = core_vehicles.spawnNewVehicle(matConfig.model, spawnOptions)
    if not obj then return nil end
    local propId = obj:getID()
    if not be:getObjectByID(propId) then
      obj:delete()
      return nil
    end
    local entry = {
      id = propId,
      mass = matConfig.unitType == "mass" and (matConfig.massPerProp or DEFAULT_MASS_PROP_KG) or 0,
      materialType = materialType,
      blockType = matConfig.unitType == "item" and matConfig.config or nil
    }
    table.insert(M.propQueue, entry)
    M.propQueueById[propId] = entry
    return entry
  end

  local function spawnMaterialProps(cache, materialType, matConfig, stock, count, isMassContract, nextSpawnPosition, clingToGround)
    local spawned = 0
    for _ = 1, count do
      local spawnPos = nextSpawnPosition()
      if not spawnPos then break end
      local entry = spawnMaterialProp(materialType, matConfig, spawnPos, clingToGround)
      if entry then
        spawned = spawned + 1
        stock.current = stock.current - (isMassContract and entry.mass or 1)
        cache.spawnedPropCounts[materialType] = (cache.spawnedPropCounts[materialType] or 0) + 1
        M.managePropCapacity()
      end
    end
    return spawned
  end

  -- contract still needs, the stock allows and the caps permit.
  function props.spawnJobMaterials(contractsMod, zonesMod, playerPos)
    M.cleanupStalePropEntries()
    local group = M.jobObjects.activeGroup
    if not group or not group.loading then return end
    local zone = group.loading
    local cache = zonesMod.ensureGroupCache(group, contractsMod.getCurrentGameHour)
    if not cache or not cache.materialStocks then return end
    zonesMod.ensureGroupOffRoadCentroid(group, contractsMod.getCurrentGameHour)
    local contract = contractsMod.ContractSystem.activeContract
    if not contract or not contract.materialTypeName then return end
    local compatibleMaterials = findCompatibleMaterials(group, contract.materialTypeName)
    if #compatibleMaterials == 0 then return end
    cache.spawnedPropCounts = cache.spawnedPropCounts or {}
    local isMassContract = contract.unitType ~= "item"
    local itemRequirements = isMassContract and {} or getContractMaterialRequirements(contract)
    local basePos = getRespawnBasePosition(cache, zone, zonesMod)
    if not basePos then return end
    basePos = basePos + vec3(0, 0, SPAWN_DROP_HEIGHT_M)
    local globalMaxProps = quarrySettings.propLimit(Config.settings)
    local gridSpacing = math.max(largestMaterialSize(compatibleMaterials) * GRID_SPACING_PER_SIZE, MIN_GRID_SPACING_M)
    local nextSpawnPosition, clingToGround = newSpawnPositionSource(group, basePos, zone, playerPos,
      gridSpacing, globalMaxProps + SPAWN_GRID_SPARE_CELLS)
    local loadedSet = loadedPropSet()
    local globalMaxAllowed = math.max(0, globalMaxProps - countPropsOffTruck(loadedSet))
    for _, materialType in ipairs(compatibleMaterials) do
      local matConfig = M.getMaterialConfig(materialType)
      local stock = matConfig and cache.materialStocks[materialType]
      if stock and stock.current > 0 then
        local currentlyAlive = countAliveInZone(materialType, zone, loadedSet)
        local materialRoom = materialSpawnRoom(matConfig, currentlyAlive)
        local propsToSpawn = 0
        if isMassContract then
          if contractsMod.checkContractCompletion and contractsMod.checkContractCompletion() then return end
          local propsInStock = math.floor(stock.current / (matConfig.massPerProp or DEFAULT_MASS_PROP_KG))
          propsToSpawn = math.min(propsInStock, materialRoom, globalMaxAllowed)
        else
          local stillNeeded = itemsStillNeeded(contractsMod, itemRequirements, materialType, currentlyAlive, loadedSet)
          if stillNeeded > 0 then
            propsToSpawn = math.min(stillNeeded, stock.current, materialRoom, globalMaxAllowed)
          end
        end
        if propsToSpawn > 0 then
          globalMaxAllowed = globalMaxAllowed - spawnMaterialProps(cache, materialType, matConfig, stock,
            propsToSpawn, isMassContract, nextSpawnPosition, clingToGround)
        end
      end
    end
  end

  props.set_Config = function(value) Config = value end
  return props

end
