-- Facility geometry for spawn positions and trigger containment.
-- The owner builds this part once; spawn candidates retain their shuffle order.
return function()
  local jsonCatalog = require('overhaul/lib/platform/jsonCatalog')

  local function positionComponents(vectorValue)
    if type(vectorValue) ~= "table" and type(vectorValue) ~= "cdata" and type(vectorValue) ~= "userdata" then return nil end
    local x = vectorValue.x or vectorValue[1]
    local y = vectorValue.y or vectorValue[2]
    local z = vectorValue.z or vectorValue[3]
    if not jsonCatalog.finite(x) or not jsonCatalog.finite(y) or not jsonCatalog.finite(z) then return nil end
    return x, y, z
  end

  local function toVec3(vectorValue)
    local x, y, z = positionComponents(vectorValue)
    return x and vec3(x, y, z) or nil
  end

  local function validZoneVertices(vertices)
    if type(vertices) ~= "table" then return false end
    local count = 0
    for index, vertex in pairs(vertices) do
      if not jsonCatalog.finite(index) or index < 1 or index % 1 ~= 0
        or not positionComponents(vertex) then return false end
      count = count + 1
    end
    if count < 3 then return false end
    for index = 1, count do
      if vertices[index] == nil then return false end
    end
    return true
  end

  local function triggerQuat(trigger)
    local rotation = trigger:getRotation()
    if not rotation then return quat(0, 0, 0, 1) end
    if type(rotation) == "table" then
      local x = rotation.x or rotation[1] or 0
      local y = rotation.y or rotation[2] or 0
      local z = rotation.z or rotation[3] or 0
      local w = rotation.w or rotation[4] or 1
      return quat(x, y, z, w)
    end
    return quat(rotation)
  end

  local function inverseQuat(rotationQuaternion)
    local inverseRotation = quat(rotationQuaternion)
    inverseRotation:inverse()
    return inverseRotation
  end

  local function distanceToTriggerBox(point, trigger)
    local triggerPosition = toVec3(trigger:getPosition())
    local scale = trigger:getScale()
    local halfX = (scale and scale.x or 5) * 0.5
    local halfY = (scale and scale.y or 5) * 0.5
    local halfZ = (scale and scale.z or 3) * 0.5
    local rotationQuaternion = triggerQuat(trigger)
    local inverseTriggerRotation = inverseQuat(rotationQuaternion)
    local localPoint = inverseTriggerRotation * (toVec3(point) - triggerPosition)
    local dx = math.max(-halfX, math.min(halfX, localPoint.x)) - localPoint.x
    local dy = math.max(-halfY, math.min(halfY, localPoint.y)) - localPoint.y
    local dz = math.max(-halfZ, math.min(halfZ, localPoint.z)) - localPoint.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
  end

  local function isPointInsideTriggerBox(point, trigger)
    local triggerPosition = toVec3(trigger:getPosition())
    local scale = trigger:getScale()
    local halfX = (scale and scale.x or 5) * 0.5
    local halfY = (scale and scale.y or 5) * 0.5
    local halfZ = (scale and scale.z or 3) * 0.5
    local rotationQuaternion = triggerQuat(trigger)
    local inverseTriggerRotation = inverseQuat(rotationQuaternion)
    local localPoint = inverseTriggerRotation * (toVec3(point) - triggerPosition)
    return math.abs(localPoint.x) <= halfX and math.abs(localPoint.y) <= halfY and math.abs(localPoint.z) <= halfZ
  end

  local function pointInValidPolygon2D(px, py, vertexList)
    local vertexCount = #vertexList
    local crossings = 0
    for i = 1, vertexCount do
      local j = (i % vertexCount) + 1
      local firstVertex = vertexList[i]
      local secondVertex = vertexList[j]
      local x1 = firstVertex[1] or firstVertex.x
      local y1 = firstVertex[2] or firstVertex.y
      local x2 = secondVertex[1] or secondVertex.x
      local y2 = secondVertex[2] or secondVertex.y
      if (y1 > py) ~= (y2 > py) then
        local edgeFraction = (py - y1) / (y2 - y1)
        local x = x1 + edgeFraction * (x2 - x1)
        if px < x then crossings = crossings + 1 end
      end
    end
    return (crossings % 2) == 1
  end

  local function isPointInPolygon2D(px, py, vertexList)
    return validZoneVertices(vertexList) and pointInValidPolygon2D(px, py, vertexList)
  end

  local function computeSpawnPositionsInZone(vertexList, spawnCount, spacingMeters)
    spacingMeters = tonumber(spacingMeters) or 2
    if spacingMeters <= 0 then spacingMeters = 1 end
    if not validZoneVertices(vertexList) then return {} end
    local minX, maxX = math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge
    local sumX, sumY, sumZ = 0, 0, 0
    local vertexCount = 0
    for _, vertex in ipairs(vertexList) do
      local x = vertex[1] or vertex.x
      local y = vertex[2] or vertex.y
      local z = vertex[3] or vertex.z
      minX = math.min(minX, x)
      maxX = math.max(maxX, x)
      minY = math.min(minY, y)
      maxY = math.max(maxY, y)
      sumX = sumX + x
      sumY = sumY + y
      sumZ = sumZ + z
      vertexCount = vertexCount + 1
    end
    local baseZ = sumZ / vertexCount
    local centerX = sumX / vertexCount
    local centerY = sumY / vertexCount
    local candidates = {}
    local x = minX
    while x <= maxX do
      local y = minY
      while y <= maxY do
        if pointInValidPolygon2D(x, y, vertexList) then
          table.insert(candidates, { x = x, y = y })
        end
        y = y + spacingMeters
      end
      x = x + spacingMeters
    end
    if #candidates == 0 then return {} end
    -- Keep props clustered: sort by distance to zone center and take nearest positions
    local zoneCenterX, zoneCenterY = centerX, centerY
    table.sort(candidates, function(firstCandidate, secondCandidate)
      local firstDistanceSquared = (firstCandidate.x - zoneCenterX) * (firstCandidate.x - zoneCenterX) + (firstCandidate.y - zoneCenterY) * (firstCandidate.y - zoneCenterY)
      local secondDistanceSquared = (secondCandidate.x - zoneCenterX) * (secondCandidate.x - zoneCenterX) + (secondCandidate.y - zoneCenterY) * (secondCandidate.y - zoneCenterY)
      return firstDistanceSquared < secondDistanceSquared
    end)
    local chosen = {}
    for i = 1, math.min(spawnCount, #candidates) do
      chosen[i] = candidates[i]
    end
    for i = #chosen, 2, -1 do
      local j = math.random(1, i)
      chosen[i], chosen[j] = chosen[j], chosen[i]
    end
    local positions = {}
    for i = 1, #chosen do
      local chosenPosition = chosen[i]
      table.insert(positions, vec3(chosenPosition.x, chosenPosition.y, baseZ))
    end
    return positions
  end

  local function getZoneCenter(vertexList)
    if not validZoneVertices(vertexList) then return nil end
    local sumX, sumY, sumZ = 0, 0, 0
    local validVertexCount = 0
    for _, vertex in ipairs(vertexList) do
      local x = vertex[1] or vertex.x
      local y = vertex[2] or vertex.y
      local z = vertex[3] or vertex.z
      if x and y then
        sumX = sumX + x
        sumY = sumY + y
        sumZ = sumZ + z
        validVertexCount = validVertexCount + 1
      end
    end
    if validVertexCount == 0 then return nil end
    return vec3(sumX / validVertexCount, sumY / validVertexCount, sumZ / validVertexCount)
  end

  local function isPointNear(pointA, pointB, radius)
    if not pointA or not pointB then return false end
    local radiusMeters = radius or 5
    local dx = pointA.x - pointB.x
    local dy = pointA.y - pointB.y
    local dz = pointA.z - pointB.z
    return (dx * dx + dy * dy + dz * dz) <= (radiusMeters * radiusMeters)
  end

  return {computeSpawnPositionsInZone = computeSpawnPositionsInZone, getZoneCenter = getZoneCenter,
    isPointInPolygon2D = isPointInPolygon2D, isPointInsideTriggerBox = isPointInsideTriggerBox,
    isPointNear = isPointNear, toVec3 = toVec3, validZoneVertices = validZoneVertices}

end
