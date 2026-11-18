-- Owns venue triggers, registration proximity, and interaction POIs.
-- motorsportEvents.lua installs action callbacks; drag/parking.lua owns player group parking.
local M = {}
local newParkingSpot = require('gameplay/sites/parkingSpot')
local callbacks, definitions, loadedLevel = {}, {}, nil
local owned, markerKey, parkedInside = {}, nil, false
local authoredSpot, authoredLoaded, virtualKey, virtualSpot
local registrationRouteToken, registrationRouteKey
local spectateIcon
local VIRTUAL_RADIUS = 18

local function currentLevel() return getCurrentLevelIdentifier() end

local function clearPois()
  if gameplay_rawPois and gameplay_rawPois.clear then gameplay_rawPois.clear() end
end

local function clearRegistrationRoute()
  if registrationRouteToken ~= nil and core_groundMarkers and core_groundMarkers.clearOwnedPath then
    core_groundMarkers.clearOwnedPath(registrationRouteToken)
  end
  registrationRouteToken, registrationRouteKey = nil, nil
end

local function removeOwned()
  for name, id in pairs(owned) do
    local object = scenetree.findObject(name)
    if object and object:getID() == id then object:delete() end
  end
  owned = {}
end

local function ensureLevel()
  local level = currentLevel()
  if loadedLevel == level then return end
  clearRegistrationRoute()
  removeOwned()
  loadedLevel = level
  authoredSpot, authoredLoaded, virtualKey, virtualSpot, parkedInside = nil, false, nil, nil, false
  definitions = jsonReadFile('/levels/' .. level .. '/overhaul/motorsport/motorsportInteractions.json') or {}
  local definition = definitions.spectate
  if definition and definition.name and definition.position and definition.scale and definition.rotation
    and not scenetree.findObject(definition.name) then
    local object = createObject('BeamNGTrigger')
    object:setField('triggerType', 0, 'Box')
    object:setPosition(vec3(definition.position))
    object:setScale(vec3(definition.scale))
    local rotation = quat(definition.rotation):toTorqueQuat()
    object:setField('rotation', 0, string.format('%.12g %.12g %.12g %.12g', rotation.x, rotation.y, rotation.z, rotation.w))
    object.canSave = false
    object:registerObject(definition.name)
    if scenetree.MissionGroup then scenetree.MissionGroup:addObject(object) end
    owned[definition.name] = object:getID()
  end
end

local function venueMatches(eventState)
  return eventState and eventState.level == loadedLevel and (not definitions.stripId or definitions.stripId == eventState.stripId)
end

local function spectateTrigger(eventState)
  ensureLevel()
  if not venueMatches(eventState) then return nil end
  return scenetree.findObject(definitions.spectate and definitions.spectate.name or 'dragSpectate')
end

function M.teleportToSpectator(eventState)
  local trigger = spectateTrigger(eventState)
  if not trigger or not gameplay_walk then return false, 'The spectator area is unavailable at this venue.' end
  if gameplay_walk.setWalkingMode(true, trigger:getPosition(), nil, true) == false then return false, 'Unable to move to the spectator area.' end
  return true
end

local function clearSpectateIcon()
  if spectateIcon then spectateIcon:release(); spectateIcon = nil end
end

local function updateSpectateIcon(eventState, dt)
  local trigger = eventState and (eventState.phase ~= 'complete' or eventState.venueSessionDay ~= nil) and spectateTrigger(eventState)
  if not trigger then clearSpectateIcon(); return end
  if not render_skiaIcons then extensions.load('render_skiaIcons') end
  if not render_skiaIcons then return end
  spectateIcon = spectateIcon or render_skiaIcons.getIcon({shape = 'circle', motive = 'movieCamera', color = 'orange'})
  local position = trigger:getPosition() + vec3(0, 0, 1.45)
  local delta = core_camera.getPosition() - position
  local distance = delta:length()
  local visible = distance < 60 and not (freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive())
    and castRayStatic(position, delta, distance, nil) >= distance
  spectateIcon:setVisible(visible)
  spectateIcon:update(position, render_skiaIcons.screenBoundedScale(position, .8, .02, .04), dt or 0)
end

local function virtualRegistration(eventState)
  if not eventState or eventState.level ~= loadedLevel or not eventState.stripFile then return nil end
  local key = tostring(eventState.id) .. ':' .. eventState.stripFile
  if key ~= virtualKey then
    virtualKey, virtualSpot = key, nil
    local data = jsonReadFile(eventState.stripFile)
    if type(data) == 'table' then
      local strip = data.strip or data
      if type(data.stripId) == 'string' then strip = jsonReadFile(data.stripId) or strip end
      for _, lane in ipairs(strip.lanes or {}) do
        local waypoint = lane.waypoints and lane.waypoints.spawn
        if not waypoint then
          for _, item in ipairs(lane.waypoints or {}) do if item.type == 'spawn' then waypoint = item; break end end
        end
        local transform = waypoint and waypoint.transform
        local position = transform and (transform.pos or transform.position)
        if position then
          virtualSpot = newParkingSpot({dir = '', filename = 'motorsportRegistration'}, 'dragRegistration', 1)
          virtualSpot:set(vec3(position), quat(transform.rot or transform.rotation or {0, 0, 0, 1}), vec3(4.5, 10, 6))
          break
        end
      end
    end
  end
  return virtualSpot
end

local function registrationSpot(eventState)
  ensureLevel()
  if venueMatches(eventState) then
    if not authoredLoaded then
      authoredLoaded = true
      local definition = definitions.registration
      local manager = gameplay_sites_sitesManager
      local sites = definition and definition.sitesFile and manager and manager.loadSites(definition.sitesFile)
      authoredSpot = sites and sites.parkingSpots.byName[definition.parkingSpotName or definition.name or 'dragRegistration']
    end
    if authoredSpot then return authoredSpot, true end
  end
  return virtualRegistration(eventState), false
end

local function registrationActive(eventState)
  if not eventState or eventState.phase ~= 'registration' or eventState.level ~= currentLevel() then return false end
  if eventState and eventState.roundRotation and eventState.weekendCalendar then
    return require('overhaul/events/motorsportEvents/weekendSchedule').gate(eventState, 'registration').allowed
  end
  local weather = overhaul_world_weather
  local minutes = weather and weather.getWorldMinutes and weather.getWorldMinutes()
  return not eventState.eventDay or not minutes or math.floor(minutes / 1440) == eventState.eventDay
end

local function checkInActive(eventState)
  if not eventState or eventState.checkInVersion ~= 1 or eventState.phase == 'registration' or eventState.phase == 'complete' or eventState.level ~= currentLevel() then return false end
  local progress = require('overhaul/events/motorsportEvents/weekendProgress')
  if not progress.inspectionGate(eventState).allowed or progress.spectatorOnly(eventState) then return false end
  if not progress.checkedIn(eventState) then return true end
  for _, row in ipairs(eventState.registrations or {}) do
    if not row.excluded and not row.refundPaid and not progress.inspected(eventState, row) then return true end
  end
  return false
end

function M.init(value)
  callbacks = value or {}
  ensureLevel()
end

function M.registrationPosition(eventState)
  local spot = registrationSpot(eventState)
  return spot and spot.pos
end

function M.isNearVenue(eventState, radius)
  if not eventState or eventState.level ~= currentLevel() then return false end
  local position = M.registrationPosition(eventState)
  local player = be and be:getPlayerVehicle(0)
  if not position or not player or not player.getPosition then return false end
  return player:getPosition():distance(position) <= (radius or 1500)
end

function M.nearbyRadius(eventState)
  local _, authored = registrationSpot(eventState)
  return authored and (tonumber(definitions.registration.nearbyRadius) or 30) or VIRTUAL_RADIUS
end

function M.routeRegistration(eventState)
  local position = (registrationActive(eventState) or checkInActive(eventState)) and M.registrationPosition(eventState)
  if not position then clearRegistrationRoute(); return false end
  if core_groundMarkers then
    registrationRouteToken = core_groundMarkers.setPath(position, {clearPathOnReachingTarget = true})
    registrationRouteKey = tostring(eventState.level) .. ':' .. tostring(eventState.id) .. ':' .. tostring(eventState.weekendStage or eventState.phase)
  end
  return true
end

function M.isAtRegistration(eventState)
  if not registrationActive(eventState) or gameplay_walk and gameplay_walk.isWalking() then return false end
  local player = be and be:getPlayerVehicle(0)
  local spot = player and registrationSpot(eventState)
  return spot ~= nil and spot:checkParking(player:getID(), 0, .1, .1) == true or false
end

function M.isAtCheckIn(eventState)
  if not checkInActive(eventState) or gameplay_walk and gameplay_walk.isWalking() then return false end
  local player = be and be:getPlayerVehicle(0)
  local spot = player and registrationSpot(eventState)
  return spot ~= nil and spot:checkParking(player:getID(), 0, .1, .1) == true or false
end

function M.nearbyInventoryIds(eventState)
  local inventory, rows = overhaul_career_garage_inventory, {}
  local position = (registrationActive(eventState) or checkInActive(eventState)) and M.registrationPosition(eventState)
  if not inventory or not position then return rows end
  local candidates, candidateIds = {}, {}
  for inventoryId, entry in pairs(inventory.getVehicles() or {}) do
    if entry.owned ~= false and not entry.loanType and not entry.rental then
      local vehicleId = inventory.getVehicleIdFromInventoryId(inventoryId)
      local vehicle = vehicleId and be:getObjectByID(vehicleId)
      if vehicle then
        candidates[#candidates + 1] = {inventoryId = inventoryId, vehicleId = vehicleId,
          distance = vehicle:getPosition():distance(position)}
        candidateIds[#candidateIds + 1] = vehicleId
      end
    end
  end
  local travel, rootId = overhaul_career_garage_switchMap, be:getPlayerVehicleID(0)
  local members = travel and travel.getTransportVehicleIds and travel.getTransportVehicleIds(rootId, candidateIds) or {[rootId] = true}
  for _, candidate in ipairs(candidates) do
    if members[candidate.vehicleId] then rows[#rows + 1] = candidate end
  end
  table.sort(rows, function(a, b)
    if a.distance == b.distance then return tostring(a.inventoryId) < tostring(b.inventoryId) end
    return a.distance < b.distance
  end)
  return rows
end

function M.onBeamNGTrigger(data)
  if not data or data.event ~= 'enter' or tonumber(data.subjectID) ~= tonumber(be:getPlayerVehicleID(0)) then return end
  local eventState = callbacks.activeEvent and callbacks.activeEvent()
  if not eventState or eventState.phase == 'complete' and eventState.venueSessionDay == nil or eventState.level ~= currentLevel() then return end
  if type(data.triggerName) == 'string' and (data.triggerName:sub(1, 16) == 'dragEvent_entry_' or data.triggerName:sub(1, 15) == 'dragEventEntry_') then
    if callbacks.arrive and (eventState.phase == 'complete' or registrationActive(eventState) or eventState.checkInVersion == 1
      and require('overhaul/events/motorsportEvents/weekendProgress').inspectionGate(eventState).allowed) then callbacks.arrive() end
    return
  end
  local spectate = spectateTrigger(eventState)
  if spectate and data.triggerName == spectate:getName() and gameplay_walk and gameplay_walk.isWalking()
    and callbacks.spectate then callbacks.spectate() end
end

function M.getPois(eventState, elements)
  local checkIn = checkInActive(eventState)
  if not registrationActive(eventState) and not checkIn then return end
  local spot, authored = registrationSpot(eventState)
  if not spot then return end
  elements[#elements + 1] = {id = 'motorsportRegistration', data = {type = 'motorsportRegistration', name = checkIn and 'Event check-in and inspection' or 'Event registration'},
    markerInfo = {parkingMarker = {pos = spot.pos, rot = spot.rot, scl = spot.scl, mode = 'contained',
      path = spot:getPath(), icon = 'poi_parking_rect', focus = false}}, pos = spot.pos, radius = authored and 5 or VIRTUAL_RADIUS}
end

function M.update(eventState, dt, venueActive)
  ensureLevel()
  updateSpectateIcon(venueActive ~= false and eventState or nil, dt)
  local active = registrationActive(eventState) or checkInActive(eventState)
  local key = active and tostring(eventState.level) .. ':' .. tostring(eventState.id) .. ':' .. tostring(eventState.weekendStage or eventState.phase) or nil
  if registrationRouteKey and registrationRouteKey ~= key then clearRegistrationRoute() end
  if markerKey ~= key then markerKey, parkedInside = key, false; clearPois() end
  local parked = key ~= nil and (M.isAtRegistration(eventState) or M.isAtCheckIn(eventState))
  if parked and not parkedInside then
    if callbacks.arrive then callbacks.arrive() end
    if callbacks.openRegistration then callbacks.openRegistration() end
  end
  parkedInside = parked == true
end

function M.shutdown()
  clearSpectateIcon()
  clearRegistrationRoute()
  removeOwned()
  callbacks, definitions, loadedLevel, markerKey = {}, {}, nil, nil
  authoredSpot, authoredLoaded, virtualKey, virtualSpot, parkedInside = nil, false, nil, nil, false
  clearPois()
end

return M
