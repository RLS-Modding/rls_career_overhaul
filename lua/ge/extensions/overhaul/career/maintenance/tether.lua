-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/tether.lua (BeamNG 0.40).
-- Tracks walk-away boundaries, firing callbacks before removing broken tethers.
-- The Overhaul career keeps this copy because the stock module is bound to the vanilla career.

local M = {}
local tethers = {}
local drawDebug = false

local vecX = vec3(1,0,0)
local vecY = vec3(0,1,0)
local vecZ = vec3(0,0,1)

local function checkBoxTether(tether)
  if not getPlayerVehicle(0) then return end
  local playerPos = getPlayerVehicle(0):getPosition()
  if drawDebug then
    M.drawAxisBox(tether.p1-tether.x1-tether.y1-tether.z1, tether.x1*2, tether.y1*2, tether.z1*2)
    debugDrawer:drawLine(playerPos, tether.p1, ColorF(0,0,1,0.1))
    simpleDebugText3d(string.format("%0.1fm", (tether.p1-playerPos):length()), lerp(playerPos, tether.p1, 0.5))
  end
  return not containsOBB_point(tether.p1, tether.x1, tether.y1, tether.z1, playerPos)

end
-- breaks when the player walks too far away
local function startBoxTether(startPosition, halfAxisX, halfAxisY, halfAxisZ, callback, data)
  local tether = {
    checkfun = checkBoxTether,
    p1 = startPosition, x1 = halfAxisX, y1 = halfAxisY, z1 = halfAxisZ,
    callback = callback,
    data = data
  }
  M.addTether(tether)
  return tether
end

local function startDoorTether(door, bufferLengthMeters, callback, data)
  bufferLengthMeters = bufferLengthMeters or 1
  local area = scenetree.findObject(door[1])
  if area then
    local pos, doorRotation, doorScale = area:getPosition(), quat(area:getRotation()), area:getScale()
    local zVec, yVec, xVec = doorRotation*vecZ*doorScale.z, doorRotation*vecY*doorScale.y, doorRotation*vecX*doorScale.x
    zVec = zVec:normalized() * (zVec:length() + bufferLengthMeters)
    yVec = yVec:normalized() * (yVec:length() + bufferLengthMeters)
    xVec = xVec:normalized() * (xVec:length() + bufferLengthMeters)
    return startBoxTether(pos, xVec, yVec, zVec, callback, data)
  end
end

local function checkSphereTether(tether)
  if not getPlayerVehicle(0) then return end
  local playerPos = getPlayerVehicle(0):getPosition()
  if drawDebug then
    debugDrawer:drawSphere(tether.p1, tether.r1, ColorF(1,0,0,0.2))
    debugDrawer:drawLine(playerPos, tether.p1, ColorF(0,0,1,0.1))
    simpleDebugText3d(string.format("%0.1fm", (tether.p1-playerPos):length()), lerp(playerPos, tether.p1, 0.5))
  end
  return (playerPos-tether.p1):length() > tether.r1
end
-- breaks when the player walks too far away
local function startSphereTether(startPosition, startRadiusMeters, callback, data)
  local tether = {
    checkfun = checkSphereTether,
    p1 = startPosition, r1 = startRadiusMeters,
    callback = callback,
    data = data
  }
  M.addTether(tether)
  return tether
end


local function checkCapsuleTether(tether)
  if not getPlayerVehicle(0) then return end
  local playerPos = getPlayerVehicle(0):getPosition()
  local segmentFraction, distanceMeters = playerPos:xnormDistanceToLineSegment(tether.p1, tether.p2)
  if drawDebug then
    debugDrawer:drawSphere(tether.p1, tether.r1, ColorF(1,0,0,0.2))
    debugDrawer:drawSphere(tether.p2, tether.r2, ColorF(0,1,0,0.2))
    local closestPoint = lerp(tether.p1, tether.p2, clamp(segmentFraction, 0, 1))
    debugDrawer:drawLine(playerPos, closestPoint, ColorF(0,0,1,0.1))
    debugDrawer:drawLine(tether.p1, tether.p2, ColorF(0,0,1,0.1))
    simpleDebugText3d(string.format("%0.1fm", (closestPoint-playerPos):length()), lerp(playerPos, closestPoint, 0.5))
  end

  if segmentFraction <= 0 then return (playerPos-tether.p1):length() > tether.r1 end
  if segmentFraction >= 1 then return (playerPos-tether.p2):length() > tether.r2 end
  return distanceMeters > lerp(tether.r1, tether.r2, segmentFraction)
end
-- breaks when the player walks too far away
local function startCapsuleTetherBetweenStatics(startPosition, startRadiusMeters, endPosition, endRadiusMeters, callback, data)
  local tether = {
    checkfun = checkCapsuleTether,
    p1 = startPosition, r1 = startRadiusMeters, p2 = endPosition, r2 = endRadiusMeters,
    callback = callback,
    data = data
  }
  M.addTether(tether)
  return tether
end

local function checkCapsuleTetherWithVeh(tether)
  local vehicleObject = scenetree.findObjectById(tether.vehId)
  if not vehicleObject then return true end
  tether.p2 = vehicleObject:getPosition()
  return checkCapsuleTether(tether)
end
-- breaks when the player walks too far away. one po
local function startCapsuleTetherBetweenStaticAndVehicle(startPosition, startRadiusMeters, vehId, endRadiusMeters, callback, data)
  local tether = {
    checkfun = checkWalkawayCapsuleTether,
    vehId = vehId,
    p1 = startPosition, r1 = startRadiusMeters, p2 = vec3(), r2 = endRadiusMeters,
    callback = callback,
    data = data
  }
  M.addTether(tether)
  return tether
end

M.startBoxTether = startBoxTether
M.startSphereTether = startSphereTether
M.startDoorTether = startDoorTether
M.startCapsuleTetherBetweenStaticAndVehicle = startCapsuleTetherBetweenStaticAndVehicle
M.startCapsuleTetherBetweenStatics = startCapsuleTetherBetweenStatics


local function checkVehicleTether(tether)
  if not getPlayerVehicle(0) then return end
  local playerPos = getPlayerVehicle(0):getPosition()

  local vehicleObject = scenetree.findObjectById(tether.vehId)
  if not vehicleObject then
    log("W", "tether", "Vehicle tether target " .. tostring(tether.vehId) .. " no longer exists, firing callback")
    return true
  end
  local vehiclePosition = vehicleObject:getPosition()
  if drawDebug then
    debugDrawer:drawSphere(vehiclePosition, tether.r1, ColorF(1,0,0,0.2))
    debugDrawer:drawLine(playerPos,vehiclePosition, ColorF(0,0,1,0.1))
    simpleDebugText3d(string.format("%0.1fm", (playerPos - vehiclePosition):length()), lerp(vehiclePosition, playerPos, 0.5))
  end
  -- allow tether to inverse, and call callback when the player gets too close
  if tether.inverse then
    return (playerPos - vehiclePosition):length() <= tether.r1
  else
    return (playerPos - vehiclePosition):length() > tether.r1
  end
end

local function startVehicleTether(vehId, radius, inverse, callback)
  local tether = {
    checkfun = checkVehicleTether,
    vehId = vehId,
    r1 = radius,
    callback = callback,
    inverse = inverse or false,
    data = data or {}
  }
  M.addTether(tether)
  return tether
end
M.startVehicleTether = startVehicleTether



local needsCleanup = false
local function onUpdate()
  for _, tether in ipairs(tethers) do
    if not tether.remove and tether.checkfun(tether) then
      tether.callback(tether)
      if drawDebug then
        log("I","","Broke tether!")
        dump(tether)
      end
      tether.remove = true
    end
    needsCleanup = needsCleanup or tether.remove
  end
  -- cleanup routine
  if needsCleanup then
    needsCleanup = false
    local indicesToRemove = {}
    for id, tether in ipairs(tethers) do
      if tether.remove then
        table.insert(indicesToRemove, id)
      end
    end
    -- Remove later entries first so earlier tether indices remain valid.
    for _, id in ipairs(arrayReverse(indicesToRemove)) do
      table.remove(tethers, id)
    end
    if not next(tethers) then
      M.onUpdate = nil
      extensions.hookUpdate("onUpdate")
    end
  end
end

local function addTether(tether)
  if not next(tethers) then
    M.onUpdate = onUpdate
    extensions.hookUpdate("onUpdate")
  end
  table.insert(tethers, tether)
end

local function removeTether(tether)
  if not tether then return end
  -- table.remove defaults to the last index when pos is nil, so never call it without a hit
  local id = tableFindKey(tethers, tether)
  if not id then return end
  table.remove(tethers, id)
end

M.addTether = addTether
M.removeTether = removeTether
M.onUpdate = nop




local function drawAxisBox(corner, x, y, z, clr)
  clr = clr or color(128,64,64,32)
  -- draw all faces in a loop
  for _, face in ipairs({{x,y,z},{x,z,y},{y,z,x}}) do
    local a,b,c = face[1],face[2],face[3]
    -- spokes
    debugDrawer:drawLine((corner    ), (corner+c    ), ColorF(0,0,0,0.75))
    debugDrawer:drawLine((corner+a  ), (corner+c+a  ), ColorF(0,0,0,0.75))
    debugDrawer:drawLine((corner+b  ), (corner+c+b  ), ColorF(0,0,0,0.75))
    debugDrawer:drawLine((corner+a+b), (corner+c+a+b), ColorF(0,0,0,0.75))
    -- first side
    debugDrawer:drawTriSolid(
      vec3(corner    ),
      vec3(corner+a  ),
      vec3(corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(corner+b  ),
      vec3(corner    ),
      vec3(corner+a+b),
      clr)
    -- back of first side
    debugDrawer:drawTriSolid(
      vec3(corner+a  ),
      vec3(corner    ),
      vec3(corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(corner    ),
      vec3(corner+b  ),
      vec3(corner+a+b),
      clr)
    -- other side
    debugDrawer:drawTriSolid(
      vec3(c+corner    ),
      vec3(c+corner+a  ),
      vec3(c+corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c+corner+b  ),
      vec3(c+corner    ),
      vec3(c+corner+a+b),
      clr)
    -- back of other side
    debugDrawer:drawTriSolid(
      vec3(c+corner+a  ),
      vec3(c+corner    ),
      vec3(c+corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c+corner    ),
      vec3(c+corner+b  ),
      vec3(c+corner+a+b),
      clr)
  end
end
M.drawAxisBox = drawAxisBox


return M