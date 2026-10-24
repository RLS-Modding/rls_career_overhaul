-- Quarry world markers and optional geometry diagnostics.
-- Read marker updates, debug geometry, frame drawing and public exports.
local quarrySettings = require("overhaul/jobs/quarry/settings")

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
  Config = overhaul_jobs_quarry_config
  local uiSettings = Config.settings.ui or {}
  local pulseSpeed = quarrySettings.value(uiSettings, "ui", "markerPulseSpeed")
  local rotationSpeed = quarrySettings.value(uiSettings, "ui", "markerRotationSpeed")
  local beamSpeed = quarrySettings.value(uiSettings, "ui", "markerBeamSpeed")
  local maxBeamHeight = quarrySettings.value(uiSettings, "ui", "markerMaxBeamHeight")
  local ringSpeed = quarrySettings.value(uiSettings, "ui", "markerRingExpandSpeed")
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
  Config = overhaul_jobs_quarry_config
  local uiSettings = Config.settings.ui or {}
  local pulseSpeed = quarrySettings.value(uiSettings, "ui", "zoneMarkerPulseSpeed")
  local beamSpeed = quarrySettings.value(uiSettings, "ui", "markerBeamSpeed")
  local maxBeamHeight = quarrySettings.value(uiSettings, "ui", "zoneMarkerMaxBeamHeight")
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
      if #materialNames > 0 then
        local materialsStr = table.concat(materialNames, ", ")
        local text = string.format("%s (%s)", zone.secondaryTag or "Zone", materialsStr)
        debugDrawer:drawTextAdvanced(textPos, text, ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 200))
      end
    end
  end
end

local function drawTruckBedDebug(managerMod)
  if managerMod.debugDrawCache and managerMod.debugDrawCache.bedData then
    local bedData = managerMod.debugDrawCache.bedData
    local corners = {}
    for dx = -1, 1, 2 do
      for dy = -1, 1, 2 do
        for dz = -1, 1, 2 do
          local corner = bedData.center
            + bedData.axisX * (bedData.halfWidth * dx)
            + bedData.axisY * (bedData.halfLength * dy)
            + bedData.axisZ * (bedData.halfHeight * dz)
          table.insert(corners, corner)
        end
      end
    end
    local green = ColorF(0, 1, 0, 0.8)
    local greenFaded = ColorF(0, 1, 0, 0.2)
    local edges = {
      {1,2}, {3,4}, {5,6}, {7,8},  -- Z edges
      {1,3}, {2,4}, {5,7}, {6,8},  -- Y edges
      {1,5}, {2,6}, {3,7}, {4,8}   -- X edges
    }
    for _, e in ipairs(edges) do
      debugDrawer:drawLine(corners[e[1]], corners[e[2]], green)
    end
    debugDrawer:drawSphere(bedData.center, 0.2, green)
    local floorCenter = bedData.center - bedData.axisZ * bedData.halfHeight
    debugDrawer:drawSquarePrism(
      floorCenter - bedData.axisY * bedData.halfLength,
      floorCenter + bedData.axisY * bedData.halfLength,
      Point2F(bedData.halfWidth * 2, 0.05),
      Point2F(bedData.halfWidth * 2, 0.05),
      greenFaded
    )
  end
end

local function drawLoadingZoneDebug(managerMod)
  if managerMod.jobObjects and managerMod.jobObjects.activeGroup then
    local zone = managerMod.jobObjects.activeGroup.loading
    if zone and zone.vertices then
      local yellow = ColorF(1, 1, 0, 0.6)
      local verts = zone.vertices
      for i = 1, #verts do
        local v1 = verts[i]
        local v2 = verts[(i % #verts) + 1]
        local x1, y1, z1 = v1[1] or v1.x or 0, v1[2] or v1.y or 0, v1[3] or v1.z or 0
        local x2, y2, z2 = v2[1] or v2.x or 0, v2[2] or v2.y or 0, v2[3] or v2.z or 0
        local p1 = vec3(x1, y1, z1 + 0.5)
        local p2 = vec3(x2, y2, z2 + 0.5)
        debugDrawer:drawLine(p1, p2, yellow)
        debugDrawer:drawSphere(p1, 0.3, yellow)
      end
    end
  end
end

local function drawCargoNodesDebug(managerMod)
  if managerMod.propQueue and #managerMod.propQueue > 0 then
    local gameplayConfig = extensions.overhaul_jobs_quarry_config
    local nodeStep = quarrySettings.value(gameplayConfig and gameplayConfig.settings and gameplayConfig.settings.payload, "payload", "nodeSamplingStep")
    local bedData = managerMod.debugDrawCache and managerMod.debugDrawCache.bedData
    for _, propEntry in ipairs(managerMod.propQueue) do
      local obj = be:getObjectByID(propEntry.id)
      if obj then
        local objPos = obj:getPosition()
        local tf = obj:getTransform()
        local axisX = vec3(tf:getColumn(0))
        local axisY = vec3(tf:getColumn(1))
        local axisZ = vec3(tf:getColumn(2))
        local cyan = ColorF(0, 1, 1, 0.8)
        debugDrawer:drawSphere(objPos, 0.5, cyan)
        if bedData then
          local nodeCount = obj:getNodeCount() or 0
          for i = 0, nodeCount - 1, nodeStep do
            local nodeLocalPos = obj:getNodePosition(i)
            local worldPoint = objPos - (axisX * nodeLocalPos.x) - (axisY * nodeLocalPos.y) + (axisZ * nodeLocalPos.z)
            local diff = worldPoint - bedData.center
            local localX = diff:dot(bedData.axisX)
            local localY = diff:dot(bedData.axisY)
            local localZ = diff:dot(bedData.axisZ)
            local isInside = (math.abs(localX) <= bedData.halfWidth and math.abs(localY) <= bedData.halfLength and math.abs(localZ) <= bedData.halfHeight)
            local nodeColor = isInside and ColorF(0, 1, 0, 0.9) or ColorF(1, 0, 0, 0.5)
            debugDrawer:drawSphere(worldPoint, 0.08, nodeColor)
          end
        end
      end
    end
  end
end

local function drawDebugOBB()
  if not debugOBBEnabled then return end
  local managerMod = extensions.overhaul_jobs_quarry_manager
  if not managerMod then return end
  drawTruckBedDebug(managerMod)
  drawLoadingZoneDebug(managerMod)
  drawCargoNodesDebug(managerMod)
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

M.uiAnim = uiAnim
M.uiHidden = uiHidden
M.markerAnim = markerAnim
M.debugOBBEnabled = debugOBBEnabled
M.isDebugOBBEnabled = isDebugOBBEnabled

M.drawWorkSiteMarker = drawWorkSiteMarker
M.drawZoneChoiceMarkers = drawZoneChoiceMarkers
M.drawDebugOBB = drawDebugOBB
M.toggleDebugOBB = toggleDebugOBB
M.onExtensionLoaded = function()
end

return M
