local M = {}

local Config = nil
local uiAnim = { opacity = 0, yOffset = 50, pulse = 0, targetOpacity = 0 }
local uiHidden = false
local markerAnim = { time = 0, pulseScale = 1.0, rotationAngle = 0, beamHeight = 0, ringExpand = 0 }
local debugOBBEnabled = false

local imgui = ui_imgui

local function lerp(a, b, t) return a + (b - a) * t end

local function getMixedContractBreakdown(contract)
  if not contract or contract.unitType ~= "item" or not contract.materialTypeName then
    return nil
  end

  if contract.materialRequirements and next(contract.materialRequirements) ~= nil then
    return contract.materialRequirements
  end

  return nil
end

local function drawWorkSiteMarker(dt, currentState, stateDrivingToSite, markerCleared, activeGroup)
  if currentState ~= stateDrivingToSite or markerCleared or not activeGroup or not activeGroup.loading then return end
  
  Config = gameplay_loading_config
  local uiSettings = Config.settings.ui or {}
  local pulseSpeed = uiSettings.markerPulseSpeed or 2.5
  local rotationSpeed = uiSettings.markerRotationSpeed or 0.4
  local beamSpeed = uiSettings.markerBeamSpeed or 30.0
  local maxBeamHeight = uiSettings.markerMaxBeamHeight or 12.0
  local ringSpeed = uiSettings.markerRingExpandSpeed or 1.5

  markerAnim.time = markerAnim.time + dt
  markerAnim.pulseScale = 1.0 + math.sin(markerAnim.time * pulseSpeed) * 0.1
  markerAnim.rotationAngle = markerAnim.rotationAngle + dt * rotationSpeed
  markerAnim.beamHeight = math.min(maxBeamHeight, markerAnim.beamHeight + dt * beamSpeed)
  markerAnim.ringExpand = (markerAnim.ringExpand + dt * ringSpeed) % ringSpeed

  local basePos = vec3(activeGroup.loading.center)
  local color = ColorF(0.2, 1.0, 0.4, 0.85)
  local colorFaded = ColorF(0.2, 1.0, 0.4, 0.3)
  local beamTop = basePos + vec3(0, 0, markerAnim.beamHeight)
  local beamRadius = 0.5 * markerAnim.pulseScale

  debugDrawer:drawCylinder(basePos, beamTop, beamRadius, color)
  debugDrawer:drawCylinder(basePos, beamTop, beamRadius + 0.2, colorFaded)

  local sphereRadius = 1.0 * markerAnim.pulseScale
  debugDrawer:drawSphere(beamTop, sphereRadius, color)
  debugDrawer:drawSphere(beamTop, sphereRadius + 0.3, ColorF(0.2, 1.0, 0.4, 0.15))
end

local function drawZoneChoiceMarkers(dt, currentState, stateChoosingZone, compatibleZones)
  if currentState ~= stateChoosingZone or #compatibleZones == 0 then return end

  Config = gameplay_loading_config
  local uiSettings = Config.settings.ui or {}
  local pulseSpeed = uiSettings.zoneMarkerPulseSpeed or 2.5
  local beamSpeed = uiSettings.markerBeamSpeed or 30.0
  local maxBeamHeight = uiSettings.zoneMarkerMaxBeamHeight or 15.0

  markerAnim.time = markerAnim.time + dt
  markerAnim.pulseScale = 1.0 + math.sin(markerAnim.time * pulseSpeed) * 0.15
  markerAnim.beamHeight = math.min(maxBeamHeight, markerAnim.beamHeight + dt * beamSpeed)

  for i, zone in ipairs(compatibleZones) do
    if zone.loading and zone.loading.center then
      local basePos = vec3(zone.loading.center)
      local hue = (i - 1) / math.max(1, #compatibleZones)
      local r = 0.3 + 0.7 * math.abs(math.sin(hue * 3.14159))
      local g = 0.8 + 0.2 * math.sin(markerAnim.time * 2)
      local b = 0.3 + 0.7 * math.abs(math.cos(hue * 3.14159))
      
      local color = ColorF(r, g, b, 0.85)
      local colorFaded = ColorF(r, g, b, 0.3)
      local beamTop = basePos + vec3(0, 0, markerAnim.beamHeight)
      local beamRadius = 0.6 * markerAnim.pulseScale

      debugDrawer:drawCylinder(basePos, beamTop, beamRadius, color)
      debugDrawer:drawCylinder(basePos, beamTop, beamRadius + 0.25, colorFaded)

      local sphereRadius = 1.2 * markerAnim.pulseScale
      debugDrawer:drawSphere(beamTop, sphereRadius, color)
      debugDrawer:drawSphere(beamTop, sphereRadius + 0.4, ColorF(r, g, b, 0.15))
      
      local textPos = beamTop + vec3(0, 0, 2)
      local materialNames = {}
      if zone.materials then
        for _, matKey in ipairs(zone.materials) do
          local matConfig = Config.materials and Config.materials[matKey]
          local matName = matConfig and matConfig.name or matKey
          table.insert(materialNames, matName)
        end
      elseif zone.materialType then
        local matConfig = Config.materials and Config.materials[zone.materialType]
        local matName = matConfig and matConfig.name or zone.materialType
        table.insert(materialNames, matName)
      end
      if #materialNames == 0 then return end
      local materialsStr = table.concat(materialNames, ", ")
      local text = string.format("%s (%s)", zone.secondaryTag or "Zone", materialsStr)
      debugDrawer:drawTextAdvanced(textPos, text, ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 200))
    end
  end
end

local function getQuarryStateForUI(currentState, playerMod, contractsMod, managerMod, zonesMod)
  local contractsForUI = {}
  Config = gameplay_loading_config
  for i, c in ipairs(contractsMod.ContractSystem.availableContracts or {}) do
    table.insert(contractsForUI, {
      id = c.id, name = c.name, tier = c.tier, material = c.material,
      materialTypeName = c.materialTypeName,
      requiredTons = c.requiredTons, requiredItems = c.requiredItems,
      isBulk = c.isBulk, totalPayout = c.totalPayout, paymentType = c.paymentType,
      groupTag = c.groupTag, estimatedTrips = c.estimatedTrips,
      expiresAtSimTime = c.expiresAtSimTime,
      hoursRemaining = contractsMod.getContractHoursRemaining(c), expirationHours = c.expirationHours,
      destinationName = c.destination and c.destination.name or nil,
      originZoneTag = c.destination and c.destination.originZoneTag or c.groupTag,
    })
  end

  local activeContractForUI = nil
  if contractsMod.ContractSystem.activeContract then
    local c = contractsMod.ContractSystem.activeContract
    activeContractForUI = {
      id = c.id, name = c.name, tier = c.tier, material = c.material,
      materialTypeName = c.materialTypeName,
      requiredTons = c.requiredTons, requiredItems = c.requiredItems,
      totalPayout = c.totalPayout, paymentType = c.paymentType,
      groupTag = c.groupTag, estimatedTrips = c.estimatedTrips,
      loadingZoneTag = c.loadingZoneTag,
      destinationName = c.destination and c.destination.name or nil,
    }
  end

  return {
    state = currentState,
    contractsCompleted = contractsMod.PlayerData.contractsCompleted or 0,
    availableContracts = contractsForUI,
    activeContract = activeContractForUI,
    contractProgress = {
      deliveredTons = contractsMod.ContractSystem.contractProgress and contractsMod.ContractSystem.contractProgress.deliveredTons or 0,
      totalPaidSoFar = contractsMod.ContractSystem.contractProgress and contractsMod.ContractSystem.contractProgress.totalPaidSoFar or 0,
      deliveredBlocks = contractsMod.ContractSystem.contractProgress and contractsMod.ContractSystem.contractProgress.deliveredBlocks or { big = 0, small = 0, total = 0 },
      deliveryCount = contractsMod.ContractSystem.contractProgress and contractsMod.ContractSystem.contractProgress.deliveryCount or 0
    },
    currentLoadMass = (managerMod.jobObjects.currentLoadMass or 0) / 1000,
    targetLoad = (function()
      local matType = managerMod.jobObjects.materialType
      if matType and Config.materials and Config.materials[matType] then
        local matConfig = Config.materials[matType]
        if matConfig.unitType == "mass" then
          return (matConfig.targetLoad or 25000) / 1000
        end
      end
      return nil
    end)(),
    materialType = managerMod.jobObjects.materialType or nil,
    itemBlocks = (managerMod.jobObjects.materialType ~= "rocks") and managerMod.getItemBlocksStatus() or {},
    anyItemDamaged = managerMod.jobObjects.anyItemDamaged or false,
    deliveryBlocks = managerMod.jobObjects.deliveryBlocksStatus or {},
    markerCleared = managerMod.markerCleared,
    truckStopped = managerMod.truckStoppedInLoading,
    zoneStock = managerMod.jobObjects.activeGroup and zonesMod.getZoneStockInfo(managerMod.jobObjects.activeGroup, contractsMod.getCurrentGameHour) or nil
  }
end

local function requestQuarryState(currentState, playerMod, contractsMod, managerMod, zonesMod)
  guihooks.trigger('updateQuarryState', getQuarryStateForUI(currentState, playerMod, contractsMod, managerMod, zonesMod))
end

-- Debug OBB Drawing
local function drawDebugOBB()
  if not debugOBBEnabled then return end
  
  local managerMod = extensions.gameplay_loading_manager
  if not managerMod then return end
  
  -- Draw truck bed OBB
  if managerMod.debugDrawCache and managerMod.debugDrawCache.bedData then
    local bd = managerMod.debugDrawCache.bedData
    local corners = {}
    for dx = -1, 1, 2 do
      for dy = -1, 1, 2 do
        for dz = -1, 1, 2 do
          local corner = bd.center
            + bd.axisX * (bd.halfWidth * dx)
            + bd.axisY * (bd.halfLength * dy)
            + bd.axisZ * (bd.halfHeight * dz)
          table.insert(corners, corner)
        end
      end
    end
    
    local green = ColorF(0, 1, 0, 0.8)
    local greenFaded = ColorF(0, 1, 0, 0.2)
    
    -- Draw edges
    local edges = {
      {1,2}, {3,4}, {5,6}, {7,8},  -- Z edges
      {1,3}, {2,4}, {5,7}, {6,8},  -- Y edges
      {1,5}, {2,6}, {3,7}, {4,8}   -- X edges
    }
    for _, e in ipairs(edges) do
      debugDrawer:drawLine(corners[e[1]], corners[e[2]], green)
    end
    
    -- Draw center sphere
    debugDrawer:drawSphere(bd.center, 0.2, green)
    
    -- Draw floor plane
    local floorCenter = bd.center - bd.axisZ * bd.halfHeight
    debugDrawer:drawSquarePrism(
      floorCenter - bd.axisY * bd.halfLength,
      floorCenter + bd.axisY * bd.halfLength,
      Point2F(bd.halfWidth * 2, 0.05),
      Point2F(bd.halfWidth * 2, 0.05),
      greenFaded
    )
  end
  
  -- Draw loading zone boundary
  if managerMod.jobObjects and managerMod.jobObjects.activeGroup then
    local zone = managerMod.jobObjects.activeGroup.loading
    if zone and zone.vertices then
      local yellow = ColorF(1, 1, 0, 0.6)
      local verts = zone.vertices
      for i = 1, #verts do
        local v1 = verts[i]
        local v2 = verts[(i % #verts) + 1]
        -- Handle both array format [x,y,z] and vec3/table format
        local x1, y1, z1 = v1[1] or v1.x or 0, v1[2] or v1.y or 0, v1[3] or v1.z or 0
        local x2, y2, z2 = v2[1] or v2.x or 0, v2[2] or v2.y or 0, v2[3] or v2.z or 0
        local p1 = vec3(x1, y1, z1 + 0.5)
        local p2 = vec3(x2, y2, z2 + 0.5)
        debugDrawer:drawLine(p1, p2, yellow)
        debugDrawer:drawSphere(p1, 0.3, yellow)
      end
    end
  end
  
  -- Draw props/rocks and their detection status
  if managerMod.propQueue and #managerMod.propQueue > 0 then
    local gameplayConfig = extensions.gameplay_loading_config
    local nodeStep = gameplayConfig and gameplayConfig.settings and gameplayConfig.settings.payload and gameplayConfig.settings.payload.nodeSamplingStep or 10
    local bd = managerMod.debugDrawCache and managerMod.debugDrawCache.bedData
    
    for _, propEntry in ipairs(managerMod.propQueue) do
      local obj = be:getObjectByID(propEntry.id)
      if obj then
        local objPos = obj:getPosition()
        local tf = obj:getTransform()
        local axisX = vec3(tf:getColumn(0))
        local axisY = vec3(tf:getColumn(1))
        local axisZ = vec3(tf:getColumn(2))
        
        -- Draw prop center
        local cyan = ColorF(0, 1, 1, 0.8)
        debugDrawer:drawSphere(objPos, 0.5, cyan)
        
        -- Draw sampled nodes if we have bed data
        if bd then
          local nodeCount = obj:getNodeCount() or 0
          for i = 0, nodeCount - 1, nodeStep do
            local nodeLocalPos = obj:getNodePosition(i)
            local worldPoint = objPos - (axisX * nodeLocalPos.x) - (axisY * nodeLocalPos.y) + (axisZ * nodeLocalPos.z)
            
            -- Check if node is inside truck bed
            local diff = worldPoint - bd.center
            local localX = diff:dot(bd.axisX)
            local localY = diff:dot(bd.axisY)
            local localZ = diff:dot(bd.axisZ)
            local isInside = (math.abs(localX) <= bd.halfWidth and math.abs(localY) <= bd.halfLength and math.abs(localZ) <= bd.halfHeight)
            
            local nodeColor = isInside and ColorF(0, 1, 0, 0.9) or ColorF(1, 0, 0, 0.5)
            debugDrawer:drawSphere(worldPoint, 0.08, nodeColor)
          end
        end
      end
    end
  end
end

local function toggleDebugOBB(enabled)
  if enabled == nil then
    debugOBBEnabled = not debugOBBEnabled
  else
    debugOBBEnabled = enabled
  end
  M.debugOBBEnabled = debugOBBEnabled
  return debugOBBEnabled
end

local function isDebugOBBEnabled()
  return debugOBBEnabled
end

-- API Exports
M.uiAnim = uiAnim
M.uiHidden = uiHidden
M.markerAnim = markerAnim
M.debugOBBEnabled = debugOBBEnabled
M.isDebugOBBEnabled = isDebugOBBEnabled

M.drawWorkSiteMarker = drawWorkSiteMarker
M.drawZoneChoiceMarkers = drawZoneChoiceMarkers
M.getQuarryStateForUI = getQuarryStateForUI
M.requestQuarryState = requestQuarryState
M.drawDebugOBB = drawDebugOBB
M.toggleDebugOBB = toggleDebugOBB
M.onExtensionLoaded = function()
end
 
return M

