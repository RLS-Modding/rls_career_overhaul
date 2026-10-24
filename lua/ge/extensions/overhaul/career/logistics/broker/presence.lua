-- Arrival geometry and live checks shared by board rows and collection guards.
-- Read live measurement, area construction, cached bounds, then the incremental watcher.
local M = {radius = 30}
local DEFAULT_GROUPS = {"pickUpSpots", "dropOffSpots", "inspectSpots", "accessPointsByName"}
local WATCH_GROUPS = {"pickUpSpots", "dropOffSpots", "inspectSpots", "loanerNonTrailerSpots", "loanerTrailerSpots"}
local FACILITIES_PER_FRAME = 2
local EMPTY = {}

function M.measure(area, player, coordinates, distances)
  local nearest
  if area then
    for _, spot in ipairs(area.spots or EMPTY) do
      local key = distances and (tostring(spot.facId) .. ":" .. tostring(spot.psPath or spot.pos or spot))
      local distance = distances and distances[key]
      if distance == nil then
        local pos = spot.pos or coordinates(spot)
        distance = pos and player and (player - pos):length() or false
        if distances then distances[key] = distance end
      end
      if distance then nearest = math.min(nearest or math.huge, distance) end
    end
  end
  return {facId = area and area.facId, distance = nearest,
    here = nearest ~= nil and nearest <= (area.radius or M.radius) or false}
end
function M.area(row, facility, groups)
  local origin = row.origin or {}
  local area = {facId = origin.facId, radius = facility and facility.arrivalRadius, spots = {}}
  local seen = {}
  local function add(spot)
    local path = spot.getPath and spot:getPath() or spot.psPath
    local key = path or spot
    if seen[key] then return end
    seen[key] = true
    area.spots[#area.spots + 1] = {type = path and "facilityParkingspot" or nil, facId = origin.facId, psPath = path, pos = spot.pos}
  end
  if facility then
    for _, name in ipairs(groups or DEFAULT_GROUPS) do
      for _, spot in pairs(facility[name] or {}) do add(spot.ps or spot) end
    end
  end
  -- A bare facility id has no position of its own; its spots above already cover it.
  if origin.psPath or origin.pos then add(origin) end
  return area
end

-- Prepared geometry needs no resolver or temporary vectors during a sweep.
function M.measurePrepared(area, player)
  local nearest
  for _, spot in ipairs(area.spots) do
    local pos = spot.pos
    if pos then
      local dx, dy, dz = player.x - pos.x, player.y - pos.y, player.z - pos.z
      local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
      nearest = math.min(nearest or math.huge, distance)
    end
  end
  return nearest ~= nil and nearest <= (area.radius or M.radius) or false, nearest
end

local function resolveBounds(record, coordinates)
  record.minX, record.minY, record.minZ = math.huge, math.huge, math.huge
  record.maxX, record.maxY, record.maxZ = -math.huge, -math.huge, -math.huge
  record.unresolved = false
  for _, spot in ipairs(record.area.spots) do
    spot.pos = spot.pos or coordinates(spot)
    local pos = spot.pos
    if pos then
      record.minX, record.minY, record.minZ = math.min(record.minX, pos.x), math.min(record.minY, pos.y), math.min(record.minZ, pos.z)
      record.maxX, record.maxY, record.maxZ = math.max(record.maxX, pos.x), math.max(record.maxY, pos.y), math.max(record.maxZ, pos.z)
    else
      record.unresolved = true
    end
  end
end

local function measureRecord(record, player)
  local dx = math.max(record.minX - player.x, 0, player.x - record.maxX)
  local dy = math.max(record.minY - player.y, 0, player.y - record.maxY)
  local dz = math.max(record.minZ - player.z, 0, player.z - record.maxZ)
  local radius = record.area.radius or M.radius
  local clearance = math.sqrt(dx*dx + dy*dy + dz*dz) - radius
  -- The bounds contain every bay, so a rejected facility cannot report arrival.
  if clearance > 0 then return false, clearance end
  local here, distance = M.measurePrepared(record.area, player)
  return here, distance and math.abs(distance - radius) or math.huge
end

local function sameFacilities(session, current)
  if #session.sources ~= #current then return false end
  for i, facility in ipairs(current) do
    if session.sources[i] ~= facility then return false end
  end
  return true
end

local function startSweep(session, getPlayer)
  local player = getPlayer()
  if not player then return false end
  local previous = session.player
  if not session.dirty and previous.x and not session.retryCoordinates then
    local dx, dy, dz = previous.x - player.x, previous.y - player.y, previous.z - player.z
    local movedSquared = dx*dx + dy*dy + dz*dz
    -- This sphere cannot reach an arrival boundary, even after many small moves.
    if movedSquared == 0 or movedSquared < session.clearance*session.clearance then return false end
  end
  previous.x, previous.y, previous.z = player.x, player.y, player.z
  for id in pairs(session.nextHere) do session.nextHere[id] = nil end
  session.index, session.clearance, session.dirty = 1, math.huge, false
  session.retryCoordinates = false
  return true
end

local function advanceSweep(session, facilities, coordinates)
  local last = math.min(session.index + FACILITIES_PER_FRAME - 1, #facilities)
  for i = session.index, last do
    local record = session.records[i]
    if not record then
      record = {area = M.area({origin = {facId = facilities[i].id}}, facilities[i], WATCH_GROUPS)}
      session.records[i] = record
      resolveBounds(record, coordinates)
    elseif record.unresolved then
      resolveBounds(record, coordinates)
    end
    local here, clearance = measureRecord(record, session.player)
    if here then session.nextHere[facilities[i].id] = true end
    -- Missing positions must be retried even when the player is stationary.
    session.clearance = math.min(session.clearance, record.unresolved and 0 or math.max(0, clearance - .001))
    session.retryCoordinates = session.retryCoordinates or record.unresolved
  end
  session.index = last + 1
  return session.index > #facilities
end

local function publishSweep(session)
  session.index = nil
  local changed = session.initial
  for id in pairs(session.here) do
    if not session.nextHere[id] then changed = true end
  end
  for id in pairs(session.nextHere) do
    if not session.here[id] then changed = true end
  end
  session.here, session.nextHere, session.initial = session.nextHere, session.here, false
  return changed
end

-- A watcher belongs to one broker session; UI and collection guards still measure live.
function M.newWatcher()
  local self, session = {}, nil
  function self.reset()
    session = {records = {}, sources = {}, here = {}, nextHere = {}, player = {}, timer = 0,
      dirty = true, initial = true, clearance = 0}
  end
  function self.invalidate()
    if session.dirty then return end
    session.records, session.index = {}, nil
    session.dirty, session.clearance = true, 0
  end
  function self.update(dt, map, facilities, getPlayer, coordinates)
    if session.map ~= map then
      self.reset()
      session.map = map
    end
    facilities = facilities or EMPTY
    session.timer = session.timer + dt
    -- A replaced facility list cancels an in-flight snapshot before publication.
    if session.facilities ~= facilities then
      if not sameFacilities(session, facilities) then self.invalidate() end
      session.facilities = facilities
    end
    if not session.index then
      if session.timer < 1 and not session.dirty then return false end
      session.timer = 0
      if not sameFacilities(session, facilities) then
        self.invalidate()
        for i in pairs(session.sources) do session.sources[i] = nil end
        for i, facility in ipairs(facilities) do session.sources[i] = facility end
      end
      if not startSweep(session, getPlayer) then return false end
    end
    if advanceSweep(session, session.sources, coordinates) then return publishSweep(session) end
    return false
  end
  self.reset()
  return self
end
return M
