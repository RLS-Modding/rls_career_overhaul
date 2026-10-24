-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/gameplay/parking.lua (BeamNG 0.40).

-- Manages parked-car spawning, spacing, pooling and driving-vehicle parking checks.
local M = {}
M.dependencies = {'core_vehicleActivePooling', 'gameplay_traffic'}

local logTag = "parking"
local parkingReservation = require('overhaul/lib/parking/reservation')

local function isReservedSpot(spot)
  return spot and (spot.ignoreOthers or (spot.customFields and spot.customFields.tags.ignoreOthers)
    or parkingReservation.isDeliveryReserved(spot))
end

local targetRadiusMeters = 50 -- radius of dynamic target point
local searchRadiusMeters = 200 -- radius of search point to query for parking spots
local searchPointDistanceMeters = 200 -- distance ahead of focus point to set search point
local keepActiveRadiusMeters = 50 -- parked cars stay active within this radius
local keepClearRadiusMeters = 120 -- parked cars avoid activating within this radius
local nearSpawnMinDistanceMeters = 18 -- nearby parked cars stay off the player's hood
local nearSpawnMaxDistanceMeters = 50 -- nearby lots around the player
local nearSpawnCount = 3 -- a few around the player; the rest spawn farther out
local pileClearRadiusMeters = 12 -- only relocate cars that spawned on top of the player
local scatterMinDistanceMeters = 45
local nearScatterMinDistanceMeters = 16
local parkedVehIds, parkedVehData = {}, {}
local trackedVehData = {} -- parking tracking, can be used with the player vehicle
local currParkingSpots = {} -- cached parking spots, updated periodically
local queuedIndex = 1

-- common functions --
local min = math.min
local max = math.max
local random = math.random

--------
local sites, vehPool, vars
local aheadPos, lastPos, debugPos, tempVec = vec3(), vec3(), vec3(), vec3()
local focus
local active = false
local resetFlag = false
local nearSpawnMode = false
local parkingSpotsAmount = 0
local respawnDelay = 0
local parkingSpawnPending = false
local pendingSpawnIsTopUp = false
local loadFixupsPending = true
local setupVehicles
local applyFarInactive
local pendingRecovery
local cancelRecovery

local function isRecovering(vehId)
  return pendingRecovery and pendingRecovery.id == vehId
end

M.debugLevel = 0

local function loadSites() -- loads sites data containing parking spots
  -- by default, the file "city.sites.json" in the root folder of the current level will be used
  if not gameplay_city then return end
  gameplay_city.loadSites()
  sites = gameplay_city.getSites()
  parkingSpotsAmount = sites and #sites.parkingSpots.sorted or 0
end

local function setSites(data) -- sets sites data, can override the default sites data
  if pendingRecovery and not cancelRecovery() then return false end
  if type(data) == "string" then
    if FS:fileExists(data) then
      sites = gameplay_sites_sitesManager.loadSites(data)
    end
  elseif type(data) == "table" and data.parkingSpots then -- assuming that given data is valid sites data
    sites = data
  else
    sites = nil
  end
  parkingSpotsAmount = sites and #sites.parkingSpots.sorted or 0
end

local function getSiteSpot(id)
  return id and sites and sites.parkingSpots and sites.parkingSpots.objects[id]
end

local function setState(val) -- activates or deactivates the parking system
  if not val and pendingRecovery and not cancelRecovery() then return false end
  active = val and true or false
  if active then
    if not sites then
      loadSites()
    end
    focus = gameplay_traffic.getFocus()
    aheadPos:set(focus.pos)
    lastPos:set(aheadPos)
  end
  return true
end

local function getState()
  return active
end

local function getParkingSpots() -- returns a table of all current parking spots
  if not sites then
    loadSites()
  end
  return sites and sites.parkingSpots
end

local function setMapmgrTracking(vehId, state) -- enables or disables mapmgr tracking for a parked vehicle (details in comments below)
  if not vehId or not parkedVehData[vehId] or not parkedVehData[vehId].parkingSpotId then return end

  local parkingSpot = getSiteSpot(parkedVehData[vehId].parkingSpotId)
  local obj = getObjectByID(vehId)
  if not parkingSpot or parkingSpot.missing or not obj then return end

  if state == nil then state = parkingSpot.customFields.tags.street end -- by default, enable tracking if parking spot street tag is present
  if state then -- enables tracking, so that active traffic can dodge this vehicle
    obj:queueLuaCommand("mapmgr.enableTracking()")
  else -- disables tracking, to optimize performance
    obj:queueLuaCommand("mapmgr.disableTracking()")
  end
end

local visibilityBox
local function isProtectedPosition(pos, box)
  -- The traffic heading is not the camera heading (orbit, look-back and free
  -- cameras). Keep nearby cars too, including cars visible in the mirrors.
  local cameraPos = core_camera.getPosition()
  if pos:squaredDistance(cameraPos) <= square(keepClearRadiusMeters)
    or (focus and pos:squaredDistance(focus.pos) <= square(keepClearRadiusMeters)) then
    return true
  end
  if Engine and Engine.sceneGetCameraFrustum and Box3F then
    if not box then
      visibilityBox = visibilityBox or Box3F()
      -- Covers a standard parking spot in any orientation, with room for
      -- placement offsets and a car whose edge is still on screen.
      visibilityBox:setExtents(vec3(10, 10, 6))
      visibilityBox:setCenter(pos)
      box = visibilityBox
    end
    return not Engine.sceneGetCameraFrustum():isBoxOutside(box)
  end
  -- Without a frustum, only recycle behind the camera. If camera direction
  -- is unavailable, leave the car in place until visibility can be checked.
  return not core_camera.getForward or (pos - cameraPos):dot(core_camera.getForward()) >= -10
end

local function canRelocateParkedCar(vehId)
  local data, obj = parkedVehData[vehId], getObjectByID(vehId)
  return obj and (not data or not data.parkingSpotId or not obj:getActive()
    or not isProtectedPosition(obj:getPosition(), obj:getWorldBox()))
end

local function finishParkingPlacement(vehId, parkingSpot)
  local obj = getObjectByID(vehId)
  obj:queueLuaCommand("electrics.setIgnitionLevel(0)")
  local data = parkedVehData[vehId]
  if data then
    local oldSpot = getSiteSpot(data.parkingSpotId)
    if oldSpot and oldSpot.vehicle == vehId then oldSpot.vehicle = nil end
    if data.randomPaint then
      core_vehicle_manager.setVehiclePaintsNames(vehId, core_vehiclePaints.getRandomPaintsByVehicle(vehId))
    end
    parkingSpot.vehicle, data.parkingSpotId = vehId, parkingSpot.id
    data.activeRadius, data._teleport, data.clearedForSpawn = 0, nil, nil
    setMapmgrTracking(vehId)
  end
  return true
end

local function moveToParkingSpot(vehId, parkingSpot, lowPrecision, initialPlacement) -- assigns a parked vehicle to a parking spot
  if isRecovering(vehId) or (parkedVehData[vehId] and parkedVehData[vehId].clearedForSpawn) then return false end
  if isReservedSpot(parkingSpot) then return end
  local obj = getObjectByID(vehId)
  if not obj then return end
  if parkedVehData[vehId] and (not canRelocateParkedCar(vehId)
    or (not initialPlacement and isProtectedPosition(parkingSpot.pos))) then return false end
  local width, length = obj.initialNodePosBB:getExtents().x - 0.1, obj.initialNodePosBB:getExtents().y
  local backwards, offsetPos, offsetRot

  if parkingSpot.customFields.tags.forwards then
    backwards = false
  elseif parkingSpot.customFields.tags.backwards then
    backwards = true
  else
    backwards = random() > 0.75 + vars.neatness * 0.25 -- backwards direction is less common by default
  end

  if not parkingSpot.customFields.tags.perfect then -- randomize position and rotation slightly
    local misalignmentFactor = 1 - square(vars.neatness)
    local widthClearance, lengthClearance = max(0, parkingSpot.scl.x - width), max(0, parkingSpot.scl.y - length)
    local xRandom, yRandom = randomGauss3() / 3 - 0.5, clamp(randomGauss3() / 3 - (backwards and 0.75 or 0.25), -0.5, 0.5)
    offsetPos = vec3(xRandom * misalignmentFactor * widthClearance, yRandom * misalignmentFactor * lengthClearance, 0)
    offsetRot = quatFromEuler(0, 0, (randomGauss3() / 3 - 0.5) * misalignmentFactor * 0.25)
  end

  local options = {
    skipVehicleIntersectionCheck = true
  }
  parkingSpot:moveResetVehicleTo(vehId, lowPrecision, backwards, offsetPos, offsetRot, true, false, nil, options)
  if M.debugLevel > 0 then
    log("I", logTag, string.format("Teleported vehId %d to parking spot %d", vehId, parkingSpot.id))
  end

  return finishParkingPlacement(vehId, parkingSpot)
end

local defaultParkingSpotSize = vec3(2.5, 6, 3)
local function checkDimensions(vehId) -- checks if the vehicle would fit in a standard sized parking spot
  local obj = getObjectByID(vehId)
  if not obj then return false end

  local extents = obj.initialNodePosBB:getExtents()
  return  extents.x <= defaultParkingSpotSize.x and
          extents.y <= defaultParkingSpotSize.y and
          extents.z <= defaultParkingSpotSize.z
end

local function checkParkingSpot(vehId, parkingSpot, minDist, maxDist) -- checks if a parking spot is ready to use for a parked vehicle
  local obj = getObjectByID(vehId or 0)
  minDist = minDist or 0
  maxDist = maxDist or 1e12

  if not parkingSpot or parkingSpot.missing or isReservedSpot(parkingSpot) then return false end

  local dist = parkingSpot.pos:squaredDistance(focus.pos)
  if dist < square(minDist) or dist > square(maxDist) then
    return false
  end

  if parkingSpot.vehicle or parkingSpot.customFields.tags.banned or parkingSpot:hasAnyVehicles() or not obj then
    return false
  end

  for _, veh in ipairs(getAllVehicles()) do
    if veh:getActive() then
      local trafficClearRadius = tonumber(veh:getDynDataFieldbyName('trafficClearRadius', 0)) -- custom radius that prevents parked cars from respawning too near
      if trafficClearRadius then
        tempVec:set(be:getObjectPositionXYZ(veh:getId()))
        if parkingSpot.pos:squaredDistance(tempVec) <= square(trafficClearRadius) then
          return false
        end
      end
    end
  end

  if parkingSpot:vehicleFits(vehId) then
    -- ensure that the parking spot is not too oversized for the vehicle
    local size = obj.initialNodePosBB:getExtents()
    local spotSize = parkingSpot.scl
    if size.x / spotSize.x < 0.5 or size.y / spotSize.y < 0.5 then
      return false
    end
  else
    return false
  end

  return true
end

local function isUsableParkingSpot(parkingSpot)
  return parkingSpot and parkingSpot.pos and not parkingSpot.missing
end

local function parkingSpotIsCloser(a, b)
  return a.squaredDistance < b.squaredDistance
end

local function getRadialParkingSpotsSafe(sitesObj, pos, minRadius, maxRadius)
  if not sitesObj or not sitesObj.quadtreeParkingSpots or not sitesObj.parkingSpots then return {} end
  local minRadiusSquared = minRadius * minRadius
  local maxRadiusSquared = maxRadius * maxRadius
  local spotEntries = {}
  pos = pos:z0()
  local objects = sitesObj.parkingSpots.objects
  for id in sitesObj.quadtreeParkingSpots:query(pos.x - maxRadius, pos.y - maxRadius, -1e30, pos.x + maxRadius, pos.y + maxRadius, 1e30) do
    local parkingSpot = rawget(objects, id)
    if isUsableParkingSpot(parkingSpot) then
      local distanceSquared = pos:squaredDistance(parkingSpot.pos:z0())
      if distanceSquared >= minRadiusSquared and distanceSquared <= maxRadiusSquared then
        table.insert(spotEntries, {ps = parkingSpot, squaredDistance = distanceSquared})
      end
    end
  end
  return spotEntries
end

local function findParkingSpots(pos, minRadius, maxRadius) -- finds and returns a sorted array of parking spot objects and distances
  if not sites then return {} end
  pos = pos or core_camera.getPosition()
  minRadius = minRadius or 0
  maxRadius = maxRadius or searchRadiusMeters

  local spotEntries = getRadialParkingSpotsSafe(sites, pos, minRadius, maxRadius)

  if M.debugLevel > 0 then
    log("I", logTag, string.format("Found and validated %d parking spots in area", #spotEntries))
  end
  table.sort(spotEntries, parkingSpotIsCloser) -- sorts from closest to farthest

  return spotEntries
end

local function updateParkingSpots(spotEntries, pos) -- updates the distances of the parking spots in the cached list
  if not spotEntries or type(spotEntries[1]) ~= "table" then return spotEntries end
  local needsSort, previousDistance = false, -math.huge
  for _, entry in ipairs(spotEntries) do
    if isUsableParkingSpot(entry.ps) then
      entry.squaredDistance = pos:squaredDistance(entry.ps.pos)
    end
    local distance = entry.squaredDistance
    -- Equal distances still use stock sorting so overlapping spots keep the same tie behavior.
    if distance <= previousDistance then needsSort = true end
    previousDistance = distance
  end

  if needsSort then table.sort(spotEntries, parkingSpotIsCloser) end
  return spotEntries
end

local emptyFilters = {}
local defaultFilters = {useProbability = true}
local function filterParkingSpots(spotEntries, filters) -- filter the sorted list of parking spots (as returned by findParkingSpots)
  if not spotEntries or type(spotEntries[1]) ~= "table" then return spotEntries end
  filters = filters or defaultFilters

  local spotCount = #spotEntries
  local timeOfDay = 0

  if filters.useProbability then
    local timeObj = core_environment.getTimeOfDay()
    if timeObj and timeObj.time then
      timeOfDay = timeObj.time
    end
  end

  for i = spotCount, 1, -1 do
    local ps = spotEntries[i].ps
    local remove = false

    if ps.customFields.tags.banned or (filters ~= emptyFilters and isReservedSpot(ps)) then
      remove = true
    end

    if filters.standardSize then
      if ps.scl.x > 3 or ps.scl.y > 8 then -- arbitrary width and length limits for standard parking spots
        remove = true
      end
    end

    if filters.checkVehicles then -- strict but slow check for other vehicles occupying this spot
      if ps:hasAnyVehicles() then
        remove = true
      end
    end

    if filters.avoidVisible and isProtectedPosition(ps.pos) then remove = true end

    if filters.useProbability then
      local spawnProbability = ps.customFields:has("probability") and ps.customFields:get("probability") or vars.baseProbability
      if type(spawnProbability) ~= "number" then spawnProbability = 1 end
      spawnProbability = spawnProbability * vars.baseProbability

      local dayValue = 0.25 + math.abs(timeOfDay - 0.5) * 1.5 -- max 1 for midday, min 0.25 for midnight
      local timeOfDayMultiplier = dayValue

      if ps.customFields.tags.nightTime then
        local nightValue = 1 - math.abs(timeOfDay - 0.5) * 1.5 -- opposite of dayValue
        if ps.customFields.tags.dayTime then
          timeOfDayMultiplier = max(timeOfDayMultiplier, nightValue)
        else
          timeOfDayMultiplier = nightValue
        end
      end
      spawnProbability = spawnProbability * timeOfDayMultiplier

      if spawnProbability <= random() then
        remove = true
      end
    end

    if remove then
      table.remove(spotEntries, i)
    end
  end

  if M.debugLevel > 0 then
    log("I", logTag, string.format("Filtered and accepted %d / %d parking spots", #spotEntries, spotCount))
  end

  return spotEntries
end

local function positionTooCloseToParked(pos, minDist, ignoreVehId)
  local minSq = square(minDist or scatterMinDistanceMeters)
  for _, vehId in ipairs(parkedVehIds) do
    if vehId ~= ignoreVehId then
      local obj = getObjectByID(vehId)
      if obj and obj:getPosition():squaredDistance(pos) < minSq then
        return true
      end
    end
  end
  return false
end

local function pickSpreadSpots(spotEntries, targetCount, minDist)
  local picked = {}
  minDist = minDist or scatterMinDistanceMeters
  local minSq = square(minDist)
  for _, entry in ipairs(spotEntries or {}) do
    if #picked >= targetCount then
      break
    end
    local parkingSpot = entry.ps
    if parkingSpot and parkingSpot.pos and not positionTooCloseToParked(parkingSpot.pos, minDist) then
      local farEnough = true
      for _, prev in ipairs(picked) do
        if parkingSpot.pos:squaredDistance(prev.ps.pos) < minSq then
          farEnough = false
          break
        end
      end
      if farEnough then
        picked[#picked + 1] = entry
      end
    end
  end
  return picked
end

local function getRandomParkingSpots(originPos, minDist, maxDist, targetCount, filters) -- returns a list of random parking spots, with a bias for origin position
  if not sites then return {} end
  originPos = originPos or core_camera.getPosition()
  minDist = minDist or 0
  maxDist = maxDist or 10000
  local radius = min(maxDist, max(minDist, 100))
  local spotEntries, spotCount

  if not targetCount or targetCount <= 0 then -- targetCount is optional
    targetCount = math.huge
    radius = maxDist
  end

  repeat -- find enough parking spots in the area
    spotEntries = findParkingSpots(originPos, minDist, radius)
    spotEntries = filterParkingSpots(spotEntries, filters)
    spotCount = #spotEntries
    radius = radius * 2
  until (spotCount >= targetCount or radius >= maxDist)

  if spotCount == 0 then return {} end
  if targetCount == math.huge then
    targetCount = max(1, math.ceil(spotCount / 4)) -- auto minimum count
  end

  local preferredSpots, alternateSpots = {}, {} -- main list contains the most favorable parking spots, alt list contains all others
  local ratio = min(0.95, 1 - (targetCount / spotCount)) -- ratio of selectable parking spots

  for i, spotEntry in ipairs(spotEntries) do
    if random() >= lerp(ratio, 1, square(i / spotCount)) then -- value is lower for nearer parking spots (lower index means shorter distance)
      table.insert(preferredSpots, spotEntry)
    else
      table.insert(alternateSpots, spotEntry)
    end
  end

  spotEntries = arrayConcat(preferredSpots, alternateSpots)
  local spreadDist = (filters and filters.scatterMinDist) or scatterMinDistanceMeters
  if targetCount and targetCount ~= math.huge then
    spotEntries = pickSpreadSpots(spotEntries, targetCount, spreadDist)
  end
  return spotEntries
end

local function forceTeleport(vehId, pos, minDist, maxDist) -- forces a parked car to teleport to a new parking spot
  if isRecovering(vehId) then return false end
  if not vars.enableRespawn then return false end
  if not parkedVehData[vehId] or parkedVehData[vehId].ignoreForceTeleport then return false end
  if not canRelocateParkedCar(vehId) then return false end

  pos = pos or core_camera.getPosition()

  local spotEntries = getRandomParkingSpots(pos, minDist, maxDist, 1, {checkVehicles = true, avoidVisible = true})
  for _, psData in ipairs(spotEntries) do
    local parkingSpot = psData.ps
    if checkParkingSpot(vehId, parkingSpot, minDist, maxDist) then
      local obj = getObjectByID(vehId)
      if obj and moveToParkingSpot(vehId, parkingSpot, not obj:isReady()) then return true end
    end
  end
  -- A failed search must not erase the old assignment or hide the car off-map.
  return false
end

-- Only traffic owned by this parking pool may be sacrificed for a requested spawn.
local function isParkedPoolVehicle(vehId)
  local obj = getObjectByID(vehId)
  if not obj or not parkedVehData[vehId] or not arrayFindValueIndex(parkedVehIds, vehId) or not vehPool then return false end
  if not arrayFindValueIndex(vehPool.activeVehs, vehId) and not arrayFindValueIndex(vehPool.inactiveVehs, vehId) then return false end
  if vehId == be:getPlayerVehicleID(0) or obj.ignoreParking
    or (obj.isPlayerControlled and obj:isPlayerControlled()) then return false end
  if (obj.isParked ~= true and obj.isParked ~= 'true') or obj.isMissionVehicle
    or (obj.missionId and obj.missionId ~= '') then return false end
  for _, inventory in pairs({overhaul = overhaul_career_garage_inventory, vanilla = career_modules_inventory}) do
    if inventory.getInventoryIdFromVehicleId and inventory.getInventoryIdFromVehicleId(vehId) then return false end
  end
  local tasks = overhaul_career_logistics_vehicleTasks
  for _, task in ipairs(tasks and tasks.getVehicleTasks and tasks.getVehicleTasks() or {}) do
    if task.vehId == vehId then return false end
  end
  return true
end

local function returnToPoolForSpawn(vehId)
  if not isParkedPoolVehicle(vehId) then return false end
  if isRecovering(vehId) and not cancelRecovery() then return false end
  local data, obj = parkedVehData[vehId], getObjectByID(vehId)
  vehPool:setVeh(vehId, false)
  if obj:getActive() then return false end
  setMapmgrTracking(vehId, false)
  local oldSpot = getSiteSpot(data.parkingSpotId)
  if oldSpot and oldSpot.vehicle == vehId then oldSpot.vehicle = nil end
  data.parkingSpotId, data.activeRadius = nil, 0
  data.clearedForSpawn, data._teleport = true, true
  return true
end

-- Inactive native OOBBs stay frozen. Stage without reading them, activate once,
-- then wait for physical placement before making the car visible or assigned.
cancelRecovery = function()
  local pending = pendingRecovery
  if not pending then return true end
  local obj, data = getObjectByID(pending.id), parkedVehData[pending.id]
  if obj == pending.obj then
    if isParkedPoolVehicle(pending.id) then
      vehPool:setVeh(pending.id, false)
      if obj:getActive() then obj:setActive(0) end
      if obj:getActive() then pending.cancelled = true; return false end
      if data then data.recoveryCooldown = 2 end
    elseif data then
      -- Ownership can change while physics catches up. Detach our suppression;
      -- the new owner controls the vehicle's transform and activation.
      vehPool:removeVeh(pending.id)
      parkedVehData[pending.id] = nil
      local index = arrayFindValueIndex(parkedVehIds, pending.id)
      if index then table.remove(parkedVehIds, index) end
    end
    obj:setMeshAlpha(pending.alpha, '')
  end
  if pending.spot.vehicle == pending.id then pending.spot.vehicle = nil end
  pendingRecovery = nil
  return true
end

local function hasRecoveryCapacity()
  local activeCount = 0
  for _, id in ipairs(parkedVehIds) do
    if be:getObjectActive(id) then activeCount = activeCount + 1 end
  end
  return activeCount < vehPool.maxActiveAmount
end

local function canStartPoolRecovery(vehId)
  local obj, data = getObjectByID(vehId), parkedVehData[vehId]
  return not pendingRecovery and isParkedPoolVehicle(vehId) and not obj:getActive()
    and (data.recoveryCooldown or 0) <= 0 and hasRecoveryCapacity()
end

local function startPoolRecovery(vehId, parkingSpot)
  if not canStartPoolRecovery(vehId) or isProtectedPosition(parkingSpot.pos) then return false end
  local obj, data = getObjectByID(vehId), parkedVehData[vehId]
  local alpha = obj.getMeshAlpha and obj:getMeshAlpha('') or 1
  pendingRecovery = {id = vehId, obj = obj, spot = parkingSpot, alpha = alpha, age = 0}
  obj:setMeshAlpha(0, '')
  local ok, staged = pcall(parkingSpot.moveResetVehicleTo, parkingSpot, vehId, true, false, nil, nil, false)
  local pos = obj:getPosition()
  -- Autoplace may adjust the returned transform's height on sloping ground.
  if not ok or not staged or not (pos:squaredDistance(staged) <= 25) then cancelRecovery(); return false end
  if isProtectedPosition(pos) then
    -- Native staging offsets can cross the visibility/nearby boundary. Reject
    -- only this candidate so a later hidden spot can recover the same member.
    if cancelRecovery() then data.recoveryCooldown = nil end
    return false
  end
  parkingSpot.vehicle = vehId -- temporary claim, also blocks other pool placements
  vehPool:setVeh(vehId, true)
  if not obj:getActive() then cancelRecovery(); return false end
  ok, pos = pcall(parkingSpot.moveResetVehicleTo, parkingSpot, vehId, nil, false, nil, nil, true, false, true,
    {skipVehicleIntersectionCheck = true})
  if not ok then cancelRecovery(); return false end
  pendingRecovery.targetPos = pos or staged
  return true
end

local function updatePoolRecovery(dt)
  for _, data in pairs(parkedVehData) do
    if data.recoveryCooldown then data.recoveryCooldown = max(0, data.recoveryCooldown - dt) end
  end
  local pending = pendingRecovery
  if not pending then return end
  pending.age = pending.age + dt
  local obj, spot = getObjectByID(pending.id), pending.spot
  if pending.cancelled or obj ~= pending.obj or not isParkedPoolVehicle(pending.id)
    or not obj:getActive() or not vars.enableRespawn or isReservedSpot(spot) or getSiteSpot(spot.id) ~= spot
    or spot.vehicle ~= pending.id or isProtectedPosition(spot.pos)
    or pending.age >= 5 then cancelRecovery(); return end
  local status = parkingReservation.getSpotOccupants(spot, pending.id)
  if status ~= 'empty' then cancelRecovery(); return end
  if spot:checkParking(pending.id, vars.precision) then
    local pos = obj:getPosition()
    -- Safe teleport returns its requested target; physical containment alone
    -- cannot prove the final transform and rendered bounds are safely hidden.
    if not (pos:squaredDistance(pending.targetPos) <= 25) or isProtectedPosition(pos, obj:getWorldBox()) then
      cancelRecovery()
      return
    end
    finishParkingPlacement(pending.id, spot)
    obj:setMeshAlpha(pending.alpha, '')
    pendingRecovery = nil
  end
end

-- Normal recycling keeps visibility protection. Requested spawns may hide the
-- occupant when normal relocation cannot find a hidden destination.
local function clearForSpawn(vehId)
  if not isParkedPoolVehicle(vehId) then return false end
  if isRecovering(vehId) then return returnToPoolForSpawn(vehId) end
  local ok, moved = pcall(forceTeleport, vehId)
  if ok and moved then return true end
  return returnToPoolForSpawn(vehId)
end

local function scatterParkedCars(vehIds, minDist, maxDist) -- randomly teleports all parked vehicles to parking spots
  vehIds = vehIds or parkedVehIds
  local spotEntries = getRandomParkingSpots(focus and focus.pos, minDist, maxDist, #vehIds, {checkVehicles = true})
  for i, vehId in ipairs(vehIds) do
    if spotEntries[i] and checkParkingSpot(vehId, spotEntries[i].ps, minDist, maxDist) then
      moveToParkingSpot(vehId, spotEntries[i].ps, not getObjectByID(vehId):isReady())
    else
      forceTeleport(vehId, nil, minDist, maxDist) -- alternative method (not efficient if this needs to be called)
    end
  end
end

local function enableTracking(vehId, autoDisable) -- enables parking spot tracking for a driving vehicle
  vehId = vehId or be:getPlayerVehicleID(0)
  if not getObjectByID(vehId) then return end

  setState(true)

  trackedVehData[vehId] = {
    isOversized = checkDimensions(vehId),
    autoDisableTracking = autoDisable and true or false,
    inside = false,
    preParked = false,
    parked = false,
    event = "none",
    aheadPos = vec3(),
    focusPos = vec3(),
    maxDist = 80,
    parkingTimer = 0
  }
end

local function disableTracking(vehId) -- disables parking spot tracking for a driving vehicle
  vehId = vehId or be:getPlayerVehicleID(0)
  trackedVehData[vehId] = nil
end

local function getTrackingData()
  return trackedVehData
end

local function getCurrentParkingSpot(vehId) -- returns the parking spot id of a properly parked vehicle (no tracked data needed)
  vehId = vehId or be:getPlayerVehicleID(0)
  if not getObjectByID(vehId) then return end

  if trackedVehData[vehId] then
    if trackedVehData[vehId].preParked then
      return trackedVehData[vehId].parkingSpotId -- existing tracked data
    end
  else
    local obj = getObjectByID(vehId)
    if not obj then return end

    local spotEntries = findParkingSpots(obj:getPosition(), 0, 15)
    if spotEntries[1] and spotEntries[1].ps:vehicleFits(vehId) and spotEntries[1].ps:checkParking(vehId, vars.precision) then
      return spotEntries[1].ps.id
    end
  end
end

local function resetParkingVars() -- resets parking variables to default
  vars = {
    precision = 0.8, -- parking precision required for valid parking
    neatness = 0, -- generated parked vehicle precision
    radiusCoef = 1, -- active radius multiplier
    baseProbability = 0.75, -- probability coefficient for spawning in parking spots (usually from 0 to 1; default 0.75 for nice scattering in parking lots)
    activeAmount = math.huge, -- number of active (visible) vehicles at a time
    enableRespawn = true  -- master respawn state; if false, disables all methods of respawning vehicles
  }
end
resetParkingVars()

local function isNoParkedMode()
  if settings.getValue('trafficParkedVehicles') == false then return true end
  local overhaulSettings = rawget(_G, 'overhaul_shell_settings')
  return overhaulSettings and overhaulSettings.getSetting and overhaulSettings.getSetting('noParkedMode')
end

local function getParkedCarCap()
  if isNoParkedMode() then
    return 0
  end

  local setting = tonumber(settings.getValue("trafficParkingAmount")) or 0
  if setting > 0 then
    return setting
  end

  if gameplay_traffic and gameplay_traffic.getIdealSpawnAmount then
    return clamp(gameplay_traffic.getIdealSpawnAmount(nil, true), 4, 20)
  end
end

local function getPoolActiveAmount(cap)
  local activeAmount = vars and tonumber(vars.activeAmount) or math.huge
  return max(0, min(cap or math.huge, activeAmount))
end

local function enforceParkedCarCap()
  local cap = getParkedCarCap()
  if cap == nil then return end

  if vehPool then
    vehPool:setMaxActiveAmount(getPoolActiveAmount(cap))
  end

  local extras = {}
  if cap <= 0 then
    for i = 1, #parkedVehIds do
      extras[#extras + 1] = parkedVehIds[i]
    end
  else
    for i = cap + 1, #parkedVehIds do
      extras[#extras + 1] = parkedVehIds[i]
    end
  end

  for _, vehId in ipairs(extras) do
    local obj = getObjectByID(vehId)
    local data = parkedVehData[vehId]
    if data then
      if sites and data.parkingSpotId then
        local parkingSpot = sites.parkingSpots.objects[data.parkingSpotId]
        if parkingSpot then parkingSpot.vehicle = nil end
      end
      parkedVehData[vehId] = nil
      local parkedVehicleIndex = arrayFindValueIndex(parkedVehIds, vehId)
      if parkedVehicleIndex then table.remove(parkedVehIds, parkedVehicleIndex) end
    end
    if obj then
      obj:delete()
    end
  end

  if extras[1] then
    log("I", logTag, string.format("Removed %d extra parked cars to honor cap of %d", #extras, cap))
  end
end

local function syncParkedCount()
  if parkingSpawnPending or not setupVehicles then
    return false
  end
  local cap = getParkedCarCap()
  if cap == nil then
    return false
  end
  enforceParkedCarCap()
  if cap <= 0 then
    return true
  end
  local missingVehicleCount = cap - #parkedVehIds
  if missingVehicleCount <= 0 then
    return true
  end
  -- Restart an empty pool with nearby cars; far-only top-ups start beyond
  -- the activation radius and would leave the player seeing no parked cars.
  return setupVehicles(missingVehicleCount, {keepCurrent = true, farOnly = parkedVehIds[1] ~= nil})
end

local function setParkingVars(data, reset) -- sets parking related variables
  if reset then resetParkingVars() end
  if type(data) ~= "table" then return end

  if data.radiusCoef then
    data.radiusCoef = clamp(data.radiusCoef, 0.25, 1000)
    for _, veh in pairs(parkedVehData) do
      veh.activeRadius = 0
    end
  end

  vars = tableMerge(vars, data)

  if data.activeAmount and vehPool then
    vehPool:setMaxActiveAmount(data.activeAmount)
    applyFarInactive()
  end
end

local function setActiveAmount(amount) -- sets the maximum amount of active (visible) vehicles
  amount = amount or math.huge
  setParkingVars({activeAmount = amount})
end

local function getParkingVars() -- gets parking related variables
  return vars
end

local function getParkedCarsAmount(activeOnly)
  return activeOnly and min(vars.activeAmount, #parkedVehIds) or #parkedVehIds
end

local function getParkedCarsList()
  return parkedVehIds
end

local function getParkedCarsData()
  return parkedVehData
end

local function getVehicleSpawnData(obj)
  local metallicPaintData = obj:getMetallicPaintData() or {}
  return {
    model = obj.jbeam or obj.JBeam or obj:getField('JBeam', '0'),
    config = obj.partConfig,
    pos = obj:getPosition(),
    rot = quatFromDir(vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp())),
    paint = createVehiclePaint(obj.color, metallicPaintData[1]),
    paint2 = createVehiclePaint(obj.colorPalette0, metallicPaintData[2]),
    paint3 = createVehiclePaint(obj.colorPalette1, metallicPaintData[3]),
    licenseText = obj:getDynDataFieldbyName("licenseText", 0),
    vehicleName = obj:getField('name', '')
  }
end

local function spawnVehicleFromData(data, clearedForSpawn)
  if not data or not data.model then return end
  local options = {
    config = data.config,
    pos = data.pos,
    rot = data.rot,
    paint = data.paint,
    paint2 = data.paint2,
    paint3 = data.paint3,
    licenseText = data.licenseText,
    vehicleName = data.vehicleName,
    autoEnterVehicle = false,
    canSpawnAnotherVehicleCheck = false,
    centeredPosition = true
  }
  if clearedForSpawn then
    -- Native spawning starts active. Stage suppressed stash members below the
    -- map, then deactivate them before registering the pool or restoring spots.
    options.pos = vec3(data.pos) - vec3(0, 0, 1000)
    options.cling, options.safeSpawn = false, false
  end
  local veh = core_vehicles.spawnNewVehicle(data.model, options)
  if veh and clearedForSpawn then veh:setActive(0) end
  return veh and veh:getID()
end

local bbCenter, vehDirection, bbHalfExtents = vec3(), vec3(), vec3()
-- Reuse the result table; callers receive the same table on each parking check.
local parkingResult = {}
local function trackParking(vehId) -- tracks parking status of a driving vehicle
  local valid = false
  table.clear(parkingResult)
  parkingResult.cornerCount = 0
  local obj = getObjectByID(vehId or 0)
  if not obj then return valid, parkingResult end

  local vehData = trackedVehData[vehId]
  bbCenter:set(be:getObjectOOBBCenterXYZ(vehId))
  vehDirection:set(obj:getDirectionVectorXYZ())
  bbHalfExtents:set(be:getObjectOOBBHalfExtentsXYZ(vehId))

  vehDirection:setScaled(bbHalfExtents.y)
  vehData.aheadPos:setAdd2(bbCenter, vehDirection) -- tracks the position ahead of the vehicle

  local maxDist = M.debugLevel >= 3 and 400 or vehData.maxDist
  if vehData.focusPos:squaredDistance(vehData.aheadPos) >= square(maxDist * 0.5) then -- focus pos and nearby parking spots low frequency update
    vehData.psList = findParkingSpots(vehData.aheadPos, 0, maxDist)
    vehData.psList = filterParkingSpots(vehData.psList, emptyFilters)
    vehData.focusPos:set(vehData.aheadPos)
  end

  vehData.psList = updateParkingSpots(vehData.psList, vehData.aheadPos) or {}

  if M.debugLevel > 0 then
    for _, v in ipairs(vehData.psList) do
      local parkingSpot = v.ps
      local spotDirection = vec3(0, 1, 0):rotated(parkingSpot.rot)
      local debugColor = parkingSpot.vehicle and ColorF(1, 0.5, 0.5, 0.2) or ColorF(1, 1, 1, 0.2)
      if parkingSpot.vehicle == vehId then debugColor = ColorF(0.5, 1, 0.5, 0.2) end
      debugDrawer:drawSquarePrism(parkingSpot.pos - spotDirection * parkingSpot.scl.y * 0.5, parkingSpot.pos + spotDirection * parkingSpot.scl.y * 0.5, Point2F(0.6, parkingSpot.scl.x), Point2F(0.6, parkingSpot.scl.x), debugColor)
    end
  end

  local nearestFittingSpot
  for _, v in ipairs(vehData.psList) do -- nearest parking spot
    if v.ps:vehicleFits(vehId) and (not v.ps.vehicle or v.ps.vehicle == vehId) then
      nearestFittingSpot = v.ps
      break
    end
  end

  if nearestFittingSpot then
    parkingResult.parkingSpotId = nearestFittingSpot.id
    parkingResult.parkingSpot = nearestFittingSpot

    if not nearestFittingSpot.vertices[1] then nearestFittingSpot:calcVerts() end
    valid, parkingResult.corners = nearestFittingSpot:checkParking(vehId, vars.precision) -- checks if all vehicle corners are inside the parking spot with respect to the precision
    for _, v in ipairs(parkingResult.corners) do
      if v then
        parkingResult.cornerCount = parkingResult.cornerCount + 1
      end
    end

    if M.debugLevel >= 2 then
      for i, v in ipairs(parkingResult.corners) do
        local debugColor = v and ColorF(0.3, 1, 0.3, 0.5) or ColorF(1, 0.3, 0.3, 0.5)
        debugDrawer:drawCylinder(nearestFittingSpot.vertices[i], nearestFittingSpot.vertices[i] + vec3(0, 0, 10), 0.05, debugColor)
      end
    end
  end

  return valid, parkingResult
end

local function processNextSpawn(vehId, ignorePool) -- processes the next vehicle to respawn
  if not vars.enableRespawn then return end
  if isRecovering(vehId) then return end
  if not canRelocateParkedCar(vehId) then return end
  local oldId, newId = vehId, vehId
  local cyclePool = false

  if not ignorePool then
    local inactiveId = vehPool.inactiveVehs[1]
    if inactiveId then
      if #vehPool.activeVehs < vehPool.maxActiveAmount then -- amount of active vehicles is less than the expected limit
        newId = inactiveId
      else
        newId, cyclePool = inactiveId, true
      end
    end
  end
  if not parkedVehData[newId] then return end
  -- A suppressed head cannot consume the next cycle while recovery is blocked.
  -- Recycle the already hidden active member until recovery can start.
  if newId ~= oldId and parkedVehData[newId].clearedForSpawn and not canStartPoolRecovery(newId) then
    newId, cyclePool = oldId, false
  end

  local addedDist = square(math.abs(focus.speed or 0) * 0.15)
  local actualClearRadius = clamp(keepClearRadiusMeters + addedDist, 15, 300)

  for _, psData in ipairs(currParkingSpots) do
    local parkingSpot = psData.ps
    if checkParkingSpot(newId, parkingSpot, actualClearRadius) and not positionTooCloseToParked(parkingSpot.pos, scatterMinDistanceMeters, newId) then
      -- Find and place the replacement before changing either active state.
      -- Cycling first can hide the old car even when no safe spot is found.
      if parkedVehData[newId].clearedForSpawn then
        if startPoolRecovery(newId, parkingSpot) then break end
      elseif moveToParkingSpot(newId, parkingSpot) then
        if cyclePool then vehPool:cycle(oldId, newId)
        else vehPool:setVeh(newId, true) end
        break
      end
    end
  end
end

local function insertVehicle(vehId, clearedForSpawn) -- inserts a new vehicle into the parked cars table
  local obj = getObjectByID(vehId)
  if obj then
    if obj.ignoreParking then
      log('I', logTag, string.format('Ignoring parking vehicle due to blocking flag: %d', vehId))
      return
    end

    if parkedVehData[vehId] then
      if clearedForSpawn then returnToPoolForSpawn(vehId) end
      return
    end

    local cap = getParkedCarCap()
    if cap and #parkedVehIds >= cap then
      log('I', logTag, string.format('Parked car cap (%d) reached, deleting extra vehicle %d', cap, vehId))
      obj:delete()
      return
    end

    if not vehPool then
      vehPool = core_vehicleActivePooling.createPool({name = "overhaulParking", maxActiveAmount = getPoolActiveAmount(cap)})
    elseif cap then
      vehPool:setMaxActiveAmount(getPoolActiveAmount(cap))
    end

    obj.uiState = 0
    obj.playerUsable = false
    obj:setDynDataFieldbyName("ignoreTraffic", 0, "true")
    obj:setDynDataFieldbyName("isParked", 0, "true")
    gameplay_walk.addVehicleToBlacklist(vehId)

    local psId = not clearedForSpawn and getCurrentParkingSpot(vehId) or nil
    if getSiteSpot(psId) then
      getSiteSpot(psId).vehicle = vehId -- saves the vehicle id to this spot
    end

    parkedVehData[vehId] = {
      parkingSpotId = psId, -- current parking spot id
      activeRadius = 0, -- radius that keeps the vehicle active if player is near
      clearedForSpawn = clearedForSpawn or nil,
      _teleport = clearedForSpawn or nil,
      randomPaint = true -- randomizes paint after respawning
    }

    -- Restore suppression before pool insertion or any nearby activation pass.
    if clearedForSpawn then obj:setActive(0) end
    table.insert(parkedVehIds, vehId)
    vehPool:insertVeh(vehId)

    setMapmgrTracking(vehId)
  end
end

local function removeVehicle(vehId) -- removes a vehicle from the parked cars table
  if parkedVehData[vehId] then
    parkedVehData[vehId] = nil
    local parkedVehicleIndex = arrayFindValueIndex(parkedVehIds, vehId)
    if parkedVehicleIndex then
      table.remove(parkedVehIds, parkedVehicleIndex)
    end
  end
end

local function deleteVehicles(amount)
  amount = amount or #parkedVehIds
  for i = amount, 1, -1 do
    local vehId = parkedVehIds[i] or 0
    local obj = getObjectByID(vehId)
    if obj then
      obj:delete()
      table.remove(parkedVehIds, i)
      parkedVehData[vehId] = nil
    end
  end
end

local function getPlayerPos()
  local pid = be:getPlayerVehicleID(0)
  if pid and pid ~= -1 then
    local obj = getObjectByID(pid)
    if obj then
      return obj:getPosition(), pid
    end
  end
  -- Walking careers have no player vehicle. With traffic and parking OFF,
  -- the automatic traffic focus can still point at the loading camera.
  local trafficFocus = gameplay_traffic.getFocus()
  if trafficFocus and trafficFocus.auto then
    return core_camera.getPosition()
  end
end

applyFarInactive = function()
  if not vehPool then return end
  if vars and type(vars.activeAmount) == 'number' and vars.activeAmount <= 0 then
    for _, vehId in ipairs(parkedVehIds) do
      vehPool:setVeh(vehId, false)
    end
    return
  end
  local origin = select(1, getPlayerPos()) or (focus and focus.pos)
  if not origin then return end
  local keepSq = square(keepActiveRadiusMeters)
  for _, vehId in ipairs(parkedVehIds) do
    local obj = getObjectByID(vehId)
    if obj and not isRecovering(vehId) then
      local data = parkedVehData[vehId]
      local keep = not data.clearedForSpawn and (obj:getPosition():squaredDistance(origin) <= keepSq
        or (data.parkingSpotId and isProtectedPosition(obj:getPosition(), obj:getWorldBox())))
      if keep then data._teleport = nil end
      vehPool:setVeh(vehId, keep and true or false)
    end
  end
end

-- Career load picks parking spots before the player vehicle exists, so initial
-- transforms are often relative to the loading camera. Pull a few cars into
-- real nearby lots once the player is actually in the world.
local function ensureNearbyParkedCars(origin)
  if not origin or not parkedVehIds[1] then return end
  local want = min(nearSpawnCount, #parkedVehIds)
  if want <= 0 then return end

  local nearCount, farIds = 0, {}
  for _, vehId in ipairs(parkedVehIds) do
    local obj = getObjectByID(vehId)
    if obj and not parkedVehData[vehId].clearedForSpawn then
      local dSq = obj:getPosition():squaredDistance(origin)
      if dSq >= square(nearSpawnMinDistanceMeters) and dSq <= square(nearSpawnMaxDistanceMeters) then
        nearCount = nearCount + 1
      else
        farIds[#farIds + 1] = vehId
      end
    end
  end

  local missingVehicleCount = want - nearCount
  if missingVehicleCount <= 0 then return end

  local spots = getRandomParkingSpots(origin, nearSpawnMinDistanceMeters, nearSpawnMaxDistanceMeters, missingVehicleCount, {checkVehicles = true, standardSize = true, scatterMinDist = nearScatterMinDistanceMeters})
  local moved = 0
  for _, vehId in ipairs(farIds) do
    local entry = spots[moved + 1]
    if not entry or not entry.ps then break end
    local obj = getObjectByID(vehId)
    if moveToParkingSpot(vehId, entry.ps, obj and not obj:isReady(), true) then
      moved = moved + 1
      if moved >= missingVehicleCount then break end
    end
  end
  if moved > 0 then
    log("I", logTag, string.format("Moved %d parked cars into nearby lots around the player", moved))
  end
end

local function activate(vehIds, isTopUp, clearedForSpawn) -- activates a group of vehicles, to allow them to teleport to new parking spots
  setState(true)
  if not sites or not vehIds then
    setState(false)
    return
  end

  for _, vehId in ipairs(vehIds) do
    insertVehicle(vehId, clearedForSpawn and clearedForSpawn[vehId])
  end

  if not parkedVehIds[1] then
    setState(false)
    return
  end

  enforceParkedCarCap()

  if loadFixupsPending and not isTopUp then
    loadFixupsPending = false
    local playerPos, playerId = getPlayerPos()
    local focusPos = playerPos or (focus and focus.pos) or core_camera.getPosition()
    local tooClose = {}
    for _, vehId in ipairs(parkedVehIds) do
      local obj = getObjectByID(vehId)
      if obj and obj:getPosition():squaredDistance(focusPos) < square(pileClearRadiusMeters) then
        tooClose[#tooClose + 1] = vehId
      end
    end
    if tooClose[1] then
      scatterParkedCars(tooClose, keepClearRadiusMeters)
    end

    ensureNearbyParkedCars(playerPos or focusPos)

    if playerId and core_camera.setVehicleCameraByIndexOffset then
      core_camera.setVehicleCameraByIndexOffset(0, 0)
    end
  end
  applyFarInactive()

  extensions.hook("onParkingVehiclesActivated", parkedVehIds)

  local amount, activeAmount = getParkedCarsAmount(), getParkedCarsAmount(true)
  log('I', logTag, string.format('Parking system started with %d active / %d total vehicles', activeAmount, amount))
end

local function deactivate() -- deactivates all parked vehicles
  if not setState(false) then return false end
  table.clear(parkedVehIds)
  table.clear(parkedVehData)
  if vehPool then
    vehPool:deletePool(true)
    vehPool = nil
  end
  extensions.hook("onParkingVehiclesDeactivated")
end

setupVehicles = function(amount, options) -- spawns and prepares simple parked vehicles
  options = options or {}

  if parkingSpawnPending then
    log("I", logTag, "Ignoring extra parked vehicle spawn; one is already in progress")
    return false
  end

  if not options.keepCurrent then
    deleteVehicles() -- clear current parked vehicles
    for _, veh in ipairs(getAllVehicles()) do
      local parked = tostring(veh.isParked) == "true" or veh:getDynDataFieldbyName("isParked", 0) == "true"
      if parked then
        veh:delete()
      end
    end
  end

  if not sites then
    loadSites()
  end

  if isNoParkedMode() then return false end

  amount = amount or -1
  if amount == -1 then
    amount = tonumber(settings.getValue("trafficParkingAmount")) or 0
    if amount == 0 then -- auto amount, as stock parking does
      amount = clamp(gameplay_traffic.getIdealSpawnAmount(nil, true), 4, 16)
    end
  end

  if amount <= 0 then
    log("I", logTag, "Parked vehicle amount to spawn is zero, now ignoring parked cars")
    return false
  end

  local group
  if type(options.vehGroup) == "table" then
    group = options.vehGroup
  else
    local params = gameplay_traffic_trafficUtils.getBaseGroupParams()
    params.allConfigs = true
    params.filters.Type = {propparked = 1}
    params.filters['Config Type'] = {police = 0, Police = 0, other = 1}
    params.minPop = 0

    group = core_multiSpawn.createGroup(amount, params)
  end

  if not group or not group[1] then
    log("I", logTag, "Parked vehicle group is empty!")
    return false
  end

  local playerPos, playerId = getPlayerPos()
  if gameplay_traffic.getFocus().auto and playerId then
    gameplay_traffic.setFocus('vehicle', {vehId = playerId})
  end

  local origin = options.pos or playerPos
  if not origin then
    local focusNow = gameplay_traffic.getFocus()
    origin = (focusNow and focusNow.pos) or core_camera.getPosition()
  end

  local filters = {checkVehicles = true, standardSize = true, scatterMinDist = scatterMinDistanceMeters,
    avoidVisible = options.farOnly}
  local nearFilters = {checkVehicles = true, standardSize = true, scatterMinDist = nearScatterMinDistanceMeters}
  local transforms, usedSpots = {}, {}
  local function appendSpotTransforms(spotEntries, limit)
    for _, entry in ipairs(spotEntries or {}) do
      if #transforms >= limit then break end
      local parkingSpot = entry.ps
      if parkingSpot and parkingSpot.id and not usedSpots[parkingSpot.id] then
        usedSpots[parkingSpot.id] = true
        table.insert(transforms, {pos = parkingSpot.pos, rot = parkingSpot.rot})
      end
    end
  end

  local nearWanted = options.farOnly and 0 or min(amount, nearSpawnCount)
  if nearWanted > 0 then
    appendSpotTransforms(getRandomParkingSpots(origin, nearSpawnMinDistanceMeters, nearSpawnMaxDistanceMeters, nearWanted, nearFilters), nearWanted)
  end
  local farWanted = amount - #transforms
  if farWanted > 0 then
    appendSpotTransforms(getRandomParkingSpots(origin, keepClearRadiusMeters, nil, farWanted, filters), amount)
  end

  if transforms[1] then
    lastPos:set(transforms[1].pos)
    amount = #transforms
  else
    if not options.bypassChecks then
      log("I", logTag, "No parking spots found, now ignoring parked cars")
      return false
    end
  end

  parkingSpawnPending = true
  -- Keeping an empty pool is still an initial spawn. It needs the load-time
  -- placement repair once the player exists, just like a normal career load.
  pendingSpawnIsTopUp = options.keepCurrent and parkedVehIds[1] ~= nil or false
  -- The game's traffic setup waits for the "autoParking" group before it reports traffic and parking ready.
  core_multiSpawn.spawnGroup(group, amount, {name = "autoParking", mode = "roadBehind", gap = 50, customTransforms = transforms, randomPaints = true})

  return true
end

local function resetAll() -- resets everything
  if pendingRecovery and not cancelRecovery() then error('Unable to stop parked pool recovery') end
  active = false
  sites = nil
  parkingSpotsAmount = 0
  parkingSpawnPending = false
  pendingSpawnIsTopUp = false
  currParkingSpots = {}
  queuedIndex = 1
  respawnDelay = 0
  nearSpawnMode = false
  resetFlag = false
  table.clear(parkedVehIds)
  table.clear(parkedVehData)
  table.clear(trackedVehData)
  if vehPool then
    vehPool:deletePool(true)
    vehPool = nil
  end
  resetParkingVars()
end

local function onVehicleGroupSpawned(vehList, groupId, groupName)
  if groupName == "autoParking" and parkingSpawnPending then
    parkingSpawnPending = false
    activate(vehList, pendingSpawnIsTopUp)
    pendingSpawnIsTopUp = false
  end
end

local function onVehicleResetted(vehId)
  -- Guard nil: props/job vehicles can fire vehicleReset before the object is
  -- queryable (e.g. quarry rock piles), which fatals vanilla parking.lua.
  local veh = getObjectByID(vehId)
  if active and veh and veh:isPlayerControlled() then
    resetFlag = true
    respawnDelay = 0.1 -- small value but above zero
  end
end

local function onVehicleDestroyed(vehId)
  if isRecovering(vehId) then cancelRecovery() end
  if parkedVehData[vehId] then
    local parkedVehicleIndex = arrayFindValueIndex(parkedVehIds, vehId)
    if parkedVehicleIndex then table.remove(parkedVehIds, parkedVehicleIndex) end
    local oldSpot = getSiteSpot(parkedVehData[vehId].parkingSpotId)
    if oldSpot then oldSpot.vehicle = nil end
    parkedVehData[vehId] = nil
  end
  if trackedVehData[vehId] then
    disableTracking(vehId)
  end
end

local function onVehicleActiveChanged(vehId, active)
  if vehPool and parkedVehData[vehId] then
    if not active then
      parkedVehData[vehId]._teleport = true
    else
      if parkedVehData[vehId].clearedForSpawn and not (isRecovering(vehId) and pendingRecovery.obj == getObjectByID(vehId)) then
        vehPool:setVeh(vehId, false)
        return
      end
      local activatedVeh = getObjectByID(vehId)
      if not activatedVeh then return end
      if parkedVehData[vehId]._teleport then -- force teleport if flag exists
        for _, otherVeh in ipairs(getAllVehicles()) do
          local otherId = otherVeh:getId()
          if otherVeh:getActive() and not parkedVehData[otherId] then
            local radius = otherVeh:isPlayerControlled() and 100 or 20
            if otherVeh:getPosition():squaredDistance(activatedVeh:getPosition()) < square(radius) then
              forceTeleport(vehId, nil, 100)
              break
            end
          end
        end
      end
    end
  end
end

local vehPos = vec3()
local function onUpdate(dt, dtSim)
  if not active or not sites then return end
  updatePoolRecovery(dt)
  if not be:getEnabled() or (freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive()) then return end

  tempVec:set(focus.dirVec)
  tempVec.z = 0
  tempVec:normalize()
  tempVec:setScaled2(tempVec, clamp(focus.speed * 2, 10, 100))
  aheadPos:setAdd2(focus.pos, tempVec)
  aheadPos.z = 0

  for vehId, data in pairs(trackedVehData) do
    local valid, pData = trackParking(vehId)
    data.parkingSpotId = pData.parkingSpotId
    data.parkingSpot = pData.parkingSpot

    if not valid then
      data.parkingTimer = 0
    end

    if pData.cornerCount >= 2 then -- at least two vehicle corners
      data.lastParkingSpotId = data.parkingSpotId
    end

    if not data.inside and pData.cornerCount > 0 then -- entered parking spot bounds
      data.inside = true
      data.event = "enter"
      extensions.hook("onVehicleParkingStatus", vehId, data)
    elseif data.inside and pData.cornerCount == 0 then -- exited parking spot bounds
      data.inside = false
      data.event = "exit"
      extensions.hook("onVehicleParkingStatus", vehId, data)
    end

    if data.lastParkingSpotId then
      if not data.parked and valid then
        data.preParked = true
        data.parkingTimer = data.parkingTimer + dtSim
        if data.parkingTimer >= 0.5 then -- valid parking (after a small delay)
          data.parked = true
          data.event = "valid"
          if getSiteSpot(data.lastParkingSpotId) then getSiteSpot(data.lastParkingSpotId).vehicle = vehId end
          extensions.hook("onVehicleParkingStatus", vehId, data)

          if data.autoDisableTracking then
            disableTracking(vehId)
          end
        end
      elseif data.preParked and not valid then -- invalid parking
        data.preParked = false
        data.parked = false
        data.event = data.inside and "invalid" or "exit"
        if getSiteSpot(data.lastParkingSpotId) then getSiteSpot(data.lastParkingSpotId).vehicle = nil end
        extensions.hook("onVehicleParkingStatus", vehId, data)
      end
    end
  end

  local parkedVehCount = #parkedVehIds
  if not parkedVehIds[1] then return end
  -- Pool membership can equal site capacity while cleared cars have no spot.
  -- Search normally so those inactive members can recover after reservations end.

  -- only search for parking spots whenever needed (whenever look ahead point is far enough from the last position)
  local targetOffsetDistSq = aheadPos:squaredDistance(lastPos)
  local actualTargetRadius = targetRadiusMeters * vars.radiusCoef
  if vars.baseProbability > 0 and respawnDelay == 0 and (targetOffsetDistSq > square(actualTargetRadius) or resetFlag) then -- updates parking spots if away from focus position
    local actualSearchPointDist = searchPointDistanceMeters

    if commands.isFreeCamera() then
      local height = max(-1e6, be:getSurfaceHeightBelow(focus.pos))
      height = focus.pos.z - height
      height = clamp(square(height) / 15, 0, 200)
      actualSearchPointDist = actualSearchPointDist + height
    end

    tempVec:set(focus.dirVec)
    tempVec.z = 0
    tempVec:normalize()

    if resetFlag then -- player vehicle teleported
      aheadPos:set(focus.pos) -- parking spot search point is at the player vehicle
      aheadPos.z = 0
      nearSpawnMode = true
      resetFlag = false
    else
      tempVec:setScaled2(tempVec, actualSearchPointDist) -- parking spot search point is ahead of the player vehicle
      aheadPos:setAdd2(focus.pos, tempVec)
      aheadPos.z = 0
    end

    currParkingSpots = findParkingSpots(aheadPos, 0, searchRadiusMeters)
    currParkingSpots = filterParkingSpots(currParkingSpots)

    if M.debugLevel >= 3 then
      debugPos:set(aheadPos)
    end

    if not nearSpawnMode then
      tempVec:resize(clamp(focus.speed * 2, 10, 100)) -- speed based search vector
    end
    aheadPos:setAdd2(focus.pos, tempVec)
    aheadPos.z = 0
    lastPos:set(aheadPos) -- set the position of the dynamic target point

    for _, vehId in ipairs(parkedVehIds) do
      parkedVehData[vehId].searchFlag = false -- reset search flag for all parked cars
    end

    respawnDelay = respawnDelay + 0.3
  end

  if nearSpawnMode and respawnDelay == 0 then nearSpawnMode = false end -- disables near spawn mode after a small delay

  if M.debugLevel >= 3 then
    local vecUpHigh = vec3(0, 0, 1000)
    local tempColor = respawnDelay > 0 and ColorF(1, 1, 1, 0.5) or ColorF(0, 1, 0, 0.5)
    debugDrawer:drawCylinder(aheadPos, aheadPos + vecUpHigh, 0.25, ColorF(1, 1, 0, 0.5))
    debugDrawer:drawCylinder(lastPos, lastPos + vecUpHigh, 0.25, tempColor)
    if core_terrain.getTerrain() then
      lastPos.z = core_terrain.getTerrainHeight(lastPos)
      debugDrawer:drawCylinder(lastPos, lastPos + vec3(0, 0, 1), targetRadiusMeters * vars.radiusCoef, ColorF(0, 1, 0, 0.1))
      lastPos.z = 0

      debugPos.z = core_terrain.getTerrainHeight(debugPos)
      debugDrawer:drawCylinder(debugPos, debugPos + vec3(0, 0, 0.5), searchRadiusMeters, ColorF(0, 1, 1, 0.1))
      debugPos.z = 0
    end
  end

  -- cycle through array of parked vehicles one at a time, to save on performance
  local currId = parkedVehIds[queuedIndex] or 0
  local currVeh = parkedVehData[currId]
  if currVeh and currVeh.clearedForSpawn and not be:getObjectActive(currId)
    and canStartPoolRecovery(currId) then
    processNextSpawn(currId, true)
  end
  if currVeh and not be:getObjectActive(currId) and currVeh.parkingSpotId then
    local obj = getObjectByID(currId)
    if obj and isProtectedPosition(obj:getPosition(), obj:getWorldBox()) then
      -- Reuse the assigned space as it comes into view instead of teleporting
      -- the inactive car somewhere else on activation.
      currVeh._teleport = nil
      vehPool:setVeh(currId, true)
    end
  end
  if be:getObjectActive(currId) and not isRecovering(currId) and not currVeh.ignoreTeleport then
    vehPos:set(be:getObjectPositionXYZ(currId))

    tempVec:setSub2(vehPos, focus.pos)
    local actualActiveRadius = max(30, keepActiveRadiusMeters * vars.radiusCoef)
    -- here, the vehicle stays active within a looser radius if the player was close to it
    currVeh.activeRadius = max(actualActiveRadius, keepClearRadiusMeters - tempVec:length(), currVeh.activeRadius)

    if not currVeh.searchFlag and currParkingSpots[1] then
      tempVec:normalize()

      local activeRadius = currVeh.activeRadius + focus.speed
      activeRadius = activeRadius + max(0, focus.dirVec:dot(tempVec)) * 150
      if square(activeRadius) < focus.pos:squaredDistance(vehPos) then -- focus pos is outside the active radius
        local valid = true

        for _, veh in ipairs(getAllVehicles()) do
          if not veh.isTraffic and not veh.isParked and map.objects[veh:getId()] then
            local mapData = map.objects[veh:getId()]
            local trafficClearRadius = tonumber(veh:getDynDataFieldbyName('trafficClearRadius', 0)) or actualActiveRadius
            if vehPos:squaredDistance(mapData.pos) < square(trafficClearRadius) then -- prevents respawning if too close
              valid = false
              break
            end
          end
        end

        if valid then
          processNextSpawn(currId)
          currVeh.searchFlag = true -- stop searching until next parking spot query
        end
      end
    end

    if currVeh._teleport and be:getObjectActive(currId) then
      forceTeleport(currId, nil, 100)
    end
  end

  queuedIndex = queuedIndex + 1
  if queuedIndex > parkedVehCount then
    queuedIndex = 1
  end

  if respawnDelay > 0 then
    respawnDelay = max(0, respawnDelay - dtSim) -- prevents rapid parking spot searching or respawning
  end
end

local function onClientStartMission()
  loadFixupsPending = true
end

local function onClientEndMission()
  resetAll()
  parkingReservation.releaseAll()
  loadFixupsPending = true
end

local function onSerialize(options)
  if pendingRecovery and not cancelRecovery() then error('Unable to serialize parked pool recovery') end
  options = type(options) == "table" and options or {}
  local vehicleSpawnData, vehicleSpawnOrder
  if options.despawnVehicles then
    vehicleSpawnData = {}
    vehicleSpawnOrder = {}
    if options.debugVehicleStashing then
      log("D", logTag, "Serializing parked vehicles for mission despawn stash")
    end
    for _, vehId in ipairs(parkedVehIds) do
      local obj = getObjectByID(vehId)
      if obj and vehId ~= options.exceptVehicleId then
        if options.debugVehicleStashing then
          log("D", logTag, string.format("Capturing parked vehicle for mission despawn stash: %d", vehId))
        end
        vehicleSpawnData[vehId] = getVehicleSpawnData(obj)
        table.insert(vehicleSpawnOrder, vehId)
      elseif obj and vehId == options.exceptVehicleId and options.debugVehicleStashing then
        log("D", logTag, string.format("Skipping mission player vehicle parking despawn: %d", vehId))
      end
    end
  end

  local clearedForSpawn = {}
  for id, parked in pairs(parkedVehData) do
    if parked.clearedForSpawn then clearedForSpawn[#clearedForSpawn + 1] = id end
  end
  local data = {active = active, debugLevel = M.debugLevel, parkedVehIds = deepcopy(parkedVehIds), trackedVehIds = tableKeys(trackedVehData), vars = deepcopy(vars), vehicleSpawnData = vehicleSpawnData, vehicleSpawnOrder = vehicleSpawnOrder, clearedForSpawn = clearedForSpawn}
  resetAll()

  if vehicleSpawnOrder then
    for _, vehId in ipairs(vehicleSpawnOrder) do
      local obj = getObjectByID(vehId)
      if obj then
        if options.debugVehicleStashing then
          log("D", logTag, string.format("Deleting parked vehicle after mission stash capture: %d", vehId))
        end
        obj:delete()
      end
    end
  end

  return data
end

local function onDeserialized(data, options)
  options = type(options) == "table" and options or {}
  local idMap = {}
  local clearedForSpawn = {}
  for _, id in ipairs(data.clearedForSpawn or {}) do clearedForSpawn[id] = true end
  if options.respawnVehicles and data.vehicleSpawnData then
    if options.debugVehicleStashing then
      log("D", logTag, "Respawning parked vehicles from mission stash")
    end
    for _, oldId in ipairs(data.vehicleSpawnOrder or tableKeysSorted(data.vehicleSpawnData)) do
      local newId = spawnVehicleFromData(data.vehicleSpawnData[oldId], clearedForSpawn[oldId])
      if newId then
        idMap[oldId] = newId
        if options.debugVehicleStashing then
          log("D", logTag, string.format("Respawned parked vehicle from mission stash: oldId=%d newId=%d", oldId, newId))
        end
      else
        log("W", logTag, string.format("Unable to respawn serialized parked vehicle: %d", oldId))
      end
    end
  end

  local restoredParkedVehIds = {}
  for _, vehId in ipairs(data.parkedVehIds or {}) do
    table.insert(restoredParkedVehIds, idMap[vehId] or vehId)
  end

  local restoredCleared = {}
  for oldId in pairs(clearedForSpawn) do restoredCleared[idMap[oldId] or oldId] = true end
  activate(restoredParkedVehIds, true, restoredCleared)
  for _, v in ipairs(data.trackedVehIds or {}) do
    enableTracking(idMap[v] or v)
  end
  setParkingVars(data.vars)
  active = data.active
  M.debugLevel = data.debugLevel
end

-- public interface
M.setSites = setSites
M.setState = setState
M.getState = getState
M.isSpawnPending = function() return parkingSpawnPending end
M.setupVehicles = setupVehicles
M.insertVehicle = insertVehicle
M.removeVehicle = removeVehicle
M.processVehicles = activate
M.activate = activate
M.deactivate = deactivate
M.deleteVehicles = deleteVehicles
M.getParkedCarsAmount = getParkedCarsAmount
M.getParkingAmount = getParkedCarsAmount
M.getParkedCarsList = getParkedCarsList
M.getParkedCarsData = getParkedCarsData
M.enableTracking = enableTracking
M.disableTracking = disableTracking
M.resetAll = resetAll

M.getTrackingData = getTrackingData
M.getParkingSpots = getParkingSpots
M.findParkingSpots = findParkingSpots
M.filterParkingSpots = filterParkingSpots
M.getRandomParkingSpots = getRandomParkingSpots
M.checkParkingSpot = checkParkingSpot
M.moveToParkingSpot = moveToParkingSpot
M.getCurrentParkingSpot = getCurrentParkingSpot
M.forceTeleport = forceTeleport
M.isParkedPoolVehicle = isParkedPoolVehicle
M.clearForSpawn = clearForSpawn
M.scatterParkedCars = scatterParkedCars
M.setActiveAmount = setActiveAmount
M.setParkingVars = setParkingVars
M.getParkingVars = getParkingVars
M.syncParkedCount = syncParkedCount

M.onUpdate = onUpdate
M.onVehicleActiveChanged = onVehicleActiveChanged
M.onVehicleResetted = onVehicleResetted
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleGroupSpawned = onVehicleGroupSpawned
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

-- Explicit exports keep unrelated helpers outside the service activation gate.
local guardedExports = {
  "setSites", "setState", "getState", "isSpawnPending", "setupVehicles",
  "insertVehicle", "removeVehicle", "processVehicles", "activate", "deactivate",
  "deleteVehicles", "getParkedCarsAmount", "getParkingAmount", "getParkedCarsList", "getParkedCarsData",
  "enableTracking", "disableTracking", "resetAll", "getTrackingData", "getParkingSpots",
  "findParkingSpots", "filterParkingSpots", "getRandomParkingSpots", "checkParkingSpot", "moveToParkingSpot",
  "getCurrentParkingSpot", "forceTeleport", "isParkedPoolVehicle", "clearForSpawn", "scatterParkedCars", "setActiveAmount", "setParkingVars",
  "getParkingVars", "syncParkedCount", "onUpdate", "onVehicleActiveChanged", "onVehicleResetted",
  "onVehicleDestroyed", "onVehicleGroupSpawned", "onClientStartMission", "onClientEndMission", "onSerialize",
  "onDeserialized",
}

return require('overhaul/lib/shell/serviceGuard')(M, onDeserialized, function()
  local data = onSerialize()
  resetAll()
  parkingReservation.releaseAll()
  return data
end, guardedExports)
