-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local layers = require("ui/apps/minimap/layers")

-- Color definitions
local clrFocus = color(255,115,10,255)
local clrFocusMuted = color(255*0.8,165*0.8,80,255)
local clrGrayMuted = color(100,100,100,255)
local clrRoadBgTransparentBlack = color(50, 50, 50, 255)
local clrNavBgBlack = color(70,70,70,255)
local clrGridWhite = color(160,160,160,255)
local clrNavBg = color(255,255,255,255)
local clrNavFg = color(0,0.4*255,1*255,255)
local clrTransparent = color(0,0,0,0)

-- State variables that need to be set by the main minimap
local width, height
local centerX, centerY
local camPos, camRot, camRotInverse
local scale, scaleInverse
local td
local offsetX, offsetY
local mode
M.dpi = 1

local camFwd, camRight = vec3(), vec3()
local camInverseFwd, camInverseRight = vec3(), vec3()
local halfWidthWithOffset = 0
local halfHeightWithOffset = 0

-- Setter function to update state from main minimap
M.setMinimapState = function(w, h, cx, cy, cp, cr, cri, s, si, textureDraw, ox, oy, minimapMode, dpi)
  width = w
  height = h
  centerX = cx
  centerY = cy
  camPos = cp
  camRot = cr
  camRotInverse = cri
  scale = s
  scaleInverse = si
  td = textureDraw
  offsetX = ox or 0
  offsetY = oy or 0
  mode = minimapMode or "circle"
  M.dpi = dpi or 1
  camFwd:set(1,0,0)
  camFwd:setRotate(camRot)
  camRight:set(0,1,0)
  camRight:setRotate(camRot)
  halfWidthWithOffset = width*0.5 + offsetX
  halfHeightWithOffset = height*0.5 + offsetY

  camInverseFwd:set(1,0,0)
  camInverseFwd:setRotate(camRotInverse)
  camInverseRight:set(0,1,0)
  camInverseRight:setRotate(camRotInverse)
end

-- Transform functions
local function worldToMap(p)
  local cp = p-camPos
  -- offset
  cp = cp / scale
  --rotate
  cp = camRot*cp

  cp:set(cp.x + width/2, height - cp.y -  height/2,0)
  return cp
end


--  local x = (source.x - camPos.x) * scaleInverse * camFwd.x + (source.y - camPos.y) * scaleInverse * camRight.x
--local y = (source.x - camPos.x) * scaleInverse * camFwd.y + (source.y - camPos.y) * scaleInverse * camRight.y
local function worldToMapXYZ(target, source)
  --target:set(source)
  local x, y = source.x, source.y
  --target:setSub(camPos)
  --target:setScaled(scaleInverse)
  x = (x - camPos.x) * scaleInverse
  y = (y - camPos.y) * scaleInverse

  --target:setRotate(camRot)
  --target:set(target.x * camFwd + target.y * camRight)
  local tX = x
  x = halfWidthWithOffset  + (tX * camFwd.x + y * camRight.x )
  y = halfHeightWithOffset - (tX * camFwd.y + y * camRight.y)

  if not (x >= -1e6 and x <= 1e6 and y >= -1e6 and y <= 1e6) then
    x, y = halfWidthWithOffset, halfHeightWithOffset
  end
  target:set(x, y,0)
end

local function worldToMapXY(x,y )
  x = (x - camPos.x) * scaleInverse
  y = (y - camPos.y) * scaleInverse

  local tX = x
  x = halfWidthWithOffset  + (tX * camFwd.x + y * camRight.x )
  y = halfHeightWithOffset - (tX * camFwd.y + y * camRight.y)

  if not (x >= -1e6 and x <= 1e6 and y >= -1e6 and y <= 1e6) then
    x, y = halfWidthWithOffset, halfHeightWithOffset
  end
  return x, y
end



local function worldToMapXYInverse(x,y )
  -- Convert from map coordinates to world coordinates
  local mapX = x - halfWidthWithOffset
  local mapY = halfHeightWithOffset - y

  -- Solve the system of equations:
  -- mapX = tX * camFwd.x + y * camRight.x
  -- mapY = tX * camFwd.y + y * camRight.y

  -- Using Cramer's rule to solve for tX and y
  local det = camFwd.x * camRight.y - camFwd.y * camRight.x
  local tX = (mapX * camRight.y - mapY * camRight.x) / det
  local worldY = (camFwd.x * mapY - camFwd.y * mapX) / det

  -- Convert back to world coordinates
  local worldX = tX / scaleInverse + camPos.x
  worldY = worldY / scaleInverse + camPos.y

  return worldX, worldY
end

local function mapToWorld(p)
  local cp = vec3(p.x-centerX, -(p.y - centerY),0)
  cp = camRotInverse * cp
  cp = cp * scale
  cp = cp + camPos
  return cp
end

-- Utility functions
M.isInsideMinimapBounds = function(pos, buffer)
  buffer = buffer or 0
  return pos.x > (offsetX + buffer)
    and pos.x < (offsetX + width - buffer)
    and pos.y > (offsetY + buffer)
    and pos.y < (offsetY + height - buffer)
end

local clampToMinimapBounds = function(pos, buffer)
  buffer = buffer or 0
  pos.x = clamp(pos.x, offsetX - buffer, offsetX + width + buffer)
  pos.y = clamp(pos.y, offsetY - buffer, offsetY + height + buffer)
end

-- Returns the clamped position and a flag indicating whether clamping happened
local centerLocal, target, fromCenter, dir = vec3(), vec3(), vec3(), vec3()
local corners = {vec3(), vec3(), vec3(), vec3()}
local edge, toP1, cross1, cross2 = vec3(), vec3(), vec3(), vec3()
local function setClampToBounds(pos, inset, maxDistance)
  inset = inset or 0
  centerLocal:set(width*0.5 + offsetX, height*0.5 + offsetY, 0)
  target:set(pos.x, pos.y, 0)

  -- Vector from center to target
  fromCenter:set(target.x - centerLocal.x, target.y - centerLocal.y, 0)
  local distance = fromCenter:length()

  if distance <= 1e-6 then
    pos:set(centerLocal.x, centerLocal.y, 0)
    return pos, false
  end

  -- Circle mode clamping (same style as compass)
  if mode == "circle" then
    local maxDistance = width*0.5 - inset
    if distance > maxDistance then
      dir:set(fromCenter)
      dir:normalize()
      pos:set(centerLocal.x + dir.x * maxDistance, centerLocal.y + dir.y * maxDistance, 0)
      return pos, true
    end
    pos:set(target)
    return pos, false
  end

  -- Rect mode clamping: intersect ray(center -> target) with inset rectangle
  local halfWidth = (width - 2 * inset) * 0.5
  local halfHeight = (height - 2 * inset) * 0.5

  -- Inside check
  if math.abs(target.x - centerLocal.x) <= halfWidth and math.abs(target.y - centerLocal.y) <= halfHeight then
    pos:set(target)
    return pos, false
  end

  -- Ray/segment intersection against rectangle edges
  corners[1]:set(offsetX + inset,           offsetY + inset,            0)
  corners[2]:set(offsetX + width - inset,   offsetY + inset,            0)
  corners[3]:set(offsetX + width - inset,   offsetY + height - inset,   0)
  corners[4]:set(offsetX + inset,           offsetY + height - inset,   0)

  dir:set(fromCenter)
  dir:normalize()

  local tMin = math.huge
  for i = 1, 4 do
    local p1 = corners[i]
    local p2 = corners[i % 4 + 1]
    edge:set(p2.x - p1.x, p2.y - p1.y, 0)
    toP1:set(p1.x - centerLocal.x, p1.y - centerLocal.y, 0)

    local cross1 = dir.x * edge.y - dir.y * edge.x
    local cross2 = toP1.x * edge.y - toP1.y * edge.x

    if math.abs(cross1) > 1e-6 then
      local t1 = cross2 / cross1
      local t2 = (toP1.x * dir.y - toP1.y * dir.x) / cross1
      if t1 > 0 and t2 >= 0 and t2 <= 1 then
        tMin = math.min(tMin, t1)
      end
    end
  end

  if tMin < math.huge then
    pos:set(centerLocal.x + dir.x * tMin, centerLocal.y + dir.y * tMin, 0)
    return pos, true
  end

  -- Fallback: return original target if no intersection found
  pos:set(target)
  return pos, false
end

-- Drawing utility functions
local strikeWidth = 3.0
local fillColor = color(254,102,1,255)
local strikeColor = color(255,255,255,255)
local circlePos = vec3()
local simpleCircle = function(pos, fill, strikeClr, radius)
  circlePos:set(pos)
  worldToMapXYZ(circlePos, circlePos)
  td:circle(circlePos.x, circlePos.y, ((radius or 6)-strikeWidth)*M.dpi, strikeWidth*M.dpi, fill or fillColor, fill or fillColor, strikeClr or strikeColor, strikeClr or strikeColor, 0, layers.GAMEPLAY_MARKERS)
end

local linePos1 = vec3()
local linePos2 = vec3()
local simpleLine = function(pos1, pos2, fill, strikeClr)
  linePos1:set(pos1)
  linePos2:set(pos2)
  worldToMapXYZ(linePos1, linePos1)
  worldToMapXYZ(linePos2, linePos2)
  td:lineRoundEnd(linePos1.x, linePos1.y, linePos2.x, linePos2.y, strikeWidth*M.dpi, strikeWidth*M.dpi, strikeWidth*M.dpi, fill or fillColor, fill or fillColor, strikeClr or strikeColor, strikeClr or strikeColor, 0, layers.GAMEPLAY_MARKERS)
end

local buffer = -14
local centerLocal, markerLocal, directionLocal, intersectionLocal = vec3(), vec3(), vec3(), vec3()
local tip, side, side1, side2 = vec3(), vec3(), vec3(), vec3()
-- Edge pointer function
local drawEdgePointer = function(pos, fill, strikeClr, radius, maxDistance)
  maxDistance = maxDistance or math.huge
  radius = radius or 6
  -- Convert world position to minimap coordinates
  circlePos:set(pos)
  worldToMapXYZ(circlePos, circlePos)

  -- Work in minimap's local coordinate system (before rotation)
  centerLocal:set(width/2 + offsetX, height/2 + offsetY, 0)

  -- Convert marker to local coordinates
  markerLocal:set(0,0,0)
  worldToMapXYZ(markerLocal, pos)

  -- Calculate direction in local coordinates
  directionLocal:set(markerLocal.x - centerLocal.x, markerLocal.y - centerLocal.y, 0)
  directionLocal:normalize()

  -- Clamp target to bounds using shared helper (account for marker radius)
  intersectionLocal:set(markerLocal)
  local _, wasClamped = setClampToBounds(intersectionLocal, buffer + radius)
  if not wasClamped then
    return false
  end

  -- Check if the real-world distance between original and clamped positions exceeds maxDistance
  if maxDistance ~= math.huge then
    -- Convert clamped minimap position back to world coordinates
    local clampedWorldPosX, clampedWorldPosY = worldToMapXYInverse(intersectionLocal.x, intersectionLocal.y)

    local realWorldDistanceSquared = (clampedWorldPosX - pos.x)^2 + (clampedWorldPosY - pos.y)^2
    if realWorldDistanceSquared > maxDistance^2 then
      return true
    end
  end

  -- Draw circle with triangle pointing toward the marker (like walking marker)
  local circleRadius = (radius-1.5)*M.dpi
  local triangleSize = (radius-3)*M.dpi
  local triangleLength = (radius+2)*M.dpi

  -- Draw triangle pointing toward marker
  tip:set(intersectionLocal.x + directionLocal.x * triangleLength, intersectionLocal.y + directionLocal.y * triangleLength, 0)

  -- Triangle sides (perpendicular to direction)
  side:set(-directionLocal.y, directionLocal.x, 0)
  side1:set(intersectionLocal.x + side.x * triangleSize, intersectionLocal.y + side.y * triangleSize, 0)
  side2:set(intersectionLocal.x - side.x * triangleSize, intersectionLocal.y - side.y * triangleSize, 0)

  -- Draw circle at intersection point
  -- Draw triangle with white border and colored fill
  td:circle(intersectionLocal.x, intersectionLocal.y, circleRadius, 1*M.dpi, clrNavBg, clrNavBg, strikeColor, strikeColor, 0, layers.ROUTE_POINTER)
  td:triangle(tip.x, tip.y, side1.x, side1.y, side2.x, side2.y, 2*M.dpi, 0, clrNavBg, clrNavBg, clrNavBg, clrNavBg, 0, layers.ROUTE_POINTER)

  td:circle(intersectionLocal.x, intersectionLocal.y, circleRadius-2*M.dpi, 0, fill or fillColor, fill or fillColor, clrTransparent, clrTransparent, 0, layers.ROUTE_POINTER)
  td:triangle(tip.x, tip.y, side1.x, side1.y, side2.x, side2.y, 0, 0, fill or fillColor, fill or fillColor, fill or fillColor, fill or fillColor, 0, layers.ROUTE_POINTER)
  return true
end

local simpleCircleWithEdgePointer = function(pos, fill, strikeClr, radius)
  if not drawEdgePointer(pos, fill, strikeClr, radius or 6) then
    simpleCircle(pos, fill, strikeClr, radius or 6)
  end
end

local center = vec3()
local simpleLineWithEdgePointer = function(pos1, pos2, fill, strikeClr)
  center:set(pos1)
  center:setAdd(pos2)
  center:setScaled(0.5)
  if not drawEdgePointer(center, fill, strikeClr) then
    simpleLine(pos1, pos2, fill, strikeClr)
  end
end



-- Expose functions
M.worldToMap = worldToMap
M.worldToMapXYZ = worldToMapXYZ
M.worldToMapXY = worldToMapXY
M.mapToWorld = mapToWorld
M.simpleCircle = simpleCircle
M.simpleLine = simpleLine
M.simpleCircleWithEdgePointer = simpleCircleWithEdgePointer
M.simpleLineWithEdgePointer = simpleLineWithEdgePointer
M.drawEdgePointer = drawEdgePointer
M.clampToMinimapBounds = clampToMinimapBounds
M.setClampToBounds = setClampToBounds
M.centerPointer = centerPointer
-- Grid drawing function
M.drawGrid = function()
  -- Grid spacing in world units (50 meters)
  local gridSpacing = 50

  -- Calculate the visible area in world coordinates
  local radius = math.max(width, height) * scale * 0.5
  local minX = camPos.x - radius
  local maxX = camPos.x + radius
  local minY = camPos.y - radius
  local maxY = camPos.y + radius

  -- Calculate grid line positions
  local startX = math.floor(minX / gridSpacing) * gridSpacing
  local endX = math.ceil(maxX / gridSpacing) * gridSpacing
  local startY = math.floor(minY / gridSpacing) * gridSpacing
  local endY = math.ceil(maxY / gridSpacing) * gridSpacing

  -- Draw vertical lines (X-axis aligned)
  for x = startX, endX, gridSpacing do
    local x1, y1 = worldToMapXY(x, minY - radius)
    local x2, y2 = worldToMapXY(x, maxY + radius)
    td:line(x1, y1, x2, y2, 0, 0, 0.5, 0.5, clrGridWhite, clrGridWhite, clrGridWhite, clrGridWhite, 0, layers.BG_GRID)
  end

  -- Draw horizontal lines (Y-axis aligned)
  for y = startY, endY, gridSpacing do
    local x1, y1 = worldToMapXY(minX - radius, y)
    local x2, y2 = worldToMapXY(maxX + radius, y)
    td:line(x1, y1, x2, y2, 0, 0, 0.5, 0.5, clrGridWhite, clrGridWhite, clrGridWhite, clrGridWhite, 0, layers.BG_GRID)
  end
end

-- Style color set data
local StyleColorSet = {
  {
    name = "Default",
    color = color(220,220,220,255),
    colorLow = color(150,150,120,255),
    colorLowest = color(150,120,100,255),
    clrFocus = clrFocus,
    clrFocusMuted = clrFocusMuted,
    gridWhite = clrGridWhite,
    navFg = clrNavFg,
    navBg = clrNavBg,
    grayMuted = clrGrayMuted,
  },
  {
    name = "Monochrome",
    color = color(200,200,200,255),
    colorLow = color(170,170,170,255),
    colorLowest = color(140,140,140,255),
    clrFocus = color(240,240,240,255),
    clrFocusMuted = color(200,200,200,255),
    gridWhite = clrGridWhite,
    navFg = color(255,255,255,255),
    navBg = color(32,32,64,255),
    grayMuted = clrGrayMuted,
  },
  {
    name = "Green",
    color = color(220,220,220,255),
    colorLow = color(120,200,120,255),
    colorLowest = color(90,150,60,255),
    clrFocus = clrFocus,
    clrFocusMuted = clrFocusMuted,
    gridWhite = clrGridWhite,
    navFg = clrNavFg,
    navBg = clrNavBg,
    grayMuted = clrGrayMuted,
  },
  {
    name = "Blue",
    color = color(220,220,220,255),
    colorLow = color(120,120,200,255),
    colorLowest = color(90,60,150,255),
    clrFocus = clrFocus,
    clrFocusMuted = clrFocusMuted,
    gridWhite = clrGridWhite,
    navFg = clrNavFg,
    navBg = clrNavBg,
    grayMuted = clrGrayMuted,
  },
  {
    name = "Orange",
    color = color(220,220,220,255),
    colorLow = color(200,180,160,255),
    colorLowest = color(180,150,100,255),
    clrFocus = clrFocus,
    clrFocusMuted = clrFocusMuted,
    gridWhite = clrGridWhite,
    navFg = clrNavFg,
    navBg = clrNavBg,
    grayMuted = clrGrayMuted,
  },
  {
    name = "Grayscale",
    color = color(220,220,220,255),
    colorLow = color(150,150,150,255),
    colorLowest = color(100,100,100,255),
    clrFocus = clrFocus,
    clrFocusMuted = clrFocusMuted,
    gridWhite = clrGridWhite,
    navFg = clrNavFg,
    navBg = clrNavBg,
    grayMuted = clrGrayMuted,
  },
}

-- Default style road color set index
local defaultStyleRoadColorSet = 1

-- Expose colors
M.colors = {
  orange = clrFocus,
  orangeMuted = clrFocusMuted,
  grayMuted = clrGrayMuted,
  roadBgTransparentBlack = clrRoadBgTransparentBlack,
  navBgBlack = clrNavBgBlack,
  gridWhite = clrGridWhite,
  navBgWhite = clrNavBg,
  navFgBlue = clrNavFg
}

-- Getter for StyleColorSet
M.getStyleColorSet = function()
  return StyleColorSet
end

-- Getter for default style color set index
M.getDefaultStyleColorSet = function()
  return defaultStyleRoadColorSet
end

-- Getter for current style colors
M.getCurrentStyleColors = function()
  local StyleColorSet = M.getStyleColorSet()
  local defaultStyleColorSet = M.getDefaultStyleColorSet()
  return StyleColorSet[defaultStyleColorSet]
end

return M