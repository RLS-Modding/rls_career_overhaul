-- Owns paddock vehicle lifetimes and group parking.
-- drag/grid.lua orders entrants; drag/runner.lua borrows ready vehicles; stop releases the owned paddock.
local M = {}
-- Toasts join the Event display stack (motorsportEvents/notify.lua); it is loaded when the first one is sent.
local function toast(text, kind, seconds) return require('overhaul/events/motorsportEvents/notify')(text, kind, seconds) end
local currentEvent, layout, spots, budget, spawnClock, gridKey
local stoppedSeconds, stationaryVehicleId = 0, nil
local parked, leased, assignments, candidates, batch = {}, {}, {}, {}, {}
local batchStarted = false
local groupNumber, groupCount, groupPrepared, playerDispatched, playerNotified, routeToken
local playerUpcoming, upcomingNotified, upcomingChecked, groupRound
local spawnFade
local grid = require('overhaul/events/motorsportEvents/drag/grid')
local roster = require('overhaul/events/motorsportEvents/drag/roster')
local qualifying = require('overhaul/events/motorsportEvents/drag/qualifying')
local qualifyingSchedule = require('overhaul/events/motorsportEvents/drag/qualifyingSchedule')

-- Site customFields.name is the authored UI label; spot.name remains the grid/routing address.
-- All player-facing callers, including the phone's shared paddock status, use this label.
function M.spotLabel(spot)
  local fields = spot and spot.customFields
  local label = fields and fields:get('name')
  if type(label) ~= 'string' or not label:find('%S') then
    label = spot and spot.name
    if type(label) ~= 'string' or label:find('_', 1, true) then return 'your staging spot' end
  end
  label = label:match('^%s*(.-)%s*$')
  return label ~= '' and label or 'your staging spot'
end

local function inside(p, b)
  return p.x >= b.minX and p.x <= b.maxX and p.y >= b.minY and p.y <= b.maxY
end

local function clearPlayerRoute()
  if routeToken ~= nil and core_groundMarkers and core_groundMarkers.clearOwnedPath then core_groundMarkers.clearOwnedPath(routeToken) end
  routeToken = nil
end

local function clearSpawnFade()
  local covered = spawnFade and spawnFade.phase ~= 'reveal'
  spawnFade = nil
  if covered then ui_fadeScreen.stop(.4) end
end

function M.stop()
  clearSpawnFade()
  local hadGrid = currentEvent ~= nil
  for _, row in pairs(parked) do
    local vehicle = be:getObjectByID(row.id)
    if vehicle and row.id ~= be:getPlayerVehicleID(0) then vehicle:delete() end
  end
  parked, leased, assignments, candidates, batch = {}, {}, {}, {}, {}
  currentEvent, layout, spots, budget, gridKey = nil, nil, nil, nil, nil
  spawnClock, stoppedSeconds, stationaryVehicleId, batchStarted = 0, 0, nil, false
  groupNumber, groupCount, groupPrepared, playerDispatched, playerNotified = nil, 0, false, false, false
  playerUpcoming, upcomingNotified, upcomingChecked, groupRound = nil, nil, nil, nil
  clearPlayerRoute()
  if hadGrid then gameplay_rawPois.clear() end
end

function M.getBudget()
  local traffic = tonumber(settings.getValue('trafficAmount')) or 0
  local parking = tonumber(settings.getValue('trafficParkedAmount')) or 0
  if overhaul_shell_settings and overhaul_shell_settings.getSetting('noParkedMode') then parking = 0 end
  return math.max(0, math.floor(traffic + parking))
end

local function playerStopped()
  local vehicle = be and be:getPlayerVehicle(0)
  return vehicle and vehicle:getVelocity():length() <= .5, vehicle
end

local function updateStationary(dtSim)
  local stopped, vehicle = playerStopped()
  local id = vehicle and vehicle:getID()
  if not stopped or id ~= stationaryVehicleId then stoppedSeconds = 0 end
  stationaryVehicleId = id
  if stopped then stoppedSeconds = stoppedSeconds + math.max(0, dtSim or 0) end
end

function M.canSpawn()
  local stopped, vehicle = playerStopped()
  if not stopped or vehicle:getID() ~= stationaryVehicleId or stoppedSeconds < 1 then
    return false
  end
  return true
end

local function beginBatch(eventState)
  clearSpawnFade()
  for _, row in pairs(parked) do
    local vehicle = be:getObjectByID(row.id)
    if vehicle and row.id ~= be:getPlayerVehicleID(0) then vehicle:delete() end
  end
  parked, assignments, candidates, batch, batchStarted = {}, {}, {}, {}, false
  local group
  group, groupCount = grid.nextGroup(eventState)
  groupNumber = group and group.number
  if group then assignments, candidates, batch = group.assignments, group.entrants, group.heats end
  if qualifyingSchedule.enabled(eventState) then
    local ordered = {}
    for _, heat in ipairs(batch) do
      for _, entrant in ipairs(heat.entrants) do if entrant.player then ordered[#ordered + 1] = heat; break end end
    end
    for _, heat in ipairs(batch) do
      local player = false
      for _, entrant in ipairs(heat.entrants) do if entrant.player then player = true; break end end
      if not player then ordered[#ordered + 1] = heat end
    end
    batch = ordered
  end
  groupPrepared, playerDispatched, playerNotified = false, false, false
  playerUpcoming, upcomingChecked = nil, nil
  groupRound = not eventState.bracket and qualifying.roundInfo(eventState.entrants).number or nil
  clearPlayerRoute()
  gameplay_rawPois.clear()
  spawnClock = 0
end

local function begin(eventState, key)
  M.stop()
  currentEvent, gridKey, budget = eventState.id, key, 0
  beginBatch(eventState)
  local layoutFile = '/levels/' .. eventState.level .. '/overhaul/motorsport/motorsportPaddock.json'
  layout = FS:fileExists(layoutFile) and jsonReadFile(layoutFile) or nil
  if not layout then return end
  if not layout.sitesFile or not FS:fileExists(layout.sitesFile) then layout = nil; return end
  local sites = gameplay_sites_sitesManager.loadSites(layout.sitesFile)
  if not sites then layout = nil; return end
  spots = {}
  local anchor = vec3(layout.anchor)
  for _, spot in ipairs(sites.parkingSpots.sorted) do
    local clear = false
    for _, area in ipairs(layout.clearAreas or {}) do if inside(spot.pos, area) then clear = true end end
    if spot.name:match('_1$') and not clear and inside(spot.pos, layout.bounds) and spot.pos:distance(anchor) <= layout.radius then
      spots[#spots + 1] = spot
    end
  end
  grid.sortSpots(spots)
  if #spots == 0 then layout, spots = nil, nil; return end
  budget = math.min(M.getBudget(), #spots, 6)
end

local function vehicleRow(entrantId)
  local row = parked[entrantId]
  if row and not be:getObjectByID(row.id) then parked[entrantId], row = nil, nil end
  return row
end

local function parkedCount()
  local count = 0
  for id in pairs(parked) do if vehicleRow(id) then count = count + 1 end end
  return count
end

local function parkedReady()
  for _, row in pairs(parked) do
    local vehicle = be:getObjectByID(row.id)
    if row.initializing or not vehicle or vehicle.isReady and not vehicle:isReady() then return false end
  end
  return true
end

local function initialTarget()
  local count = 0
  for _, entrant in ipairs(candidates) do
    if not entrant.player and grid.isEntrantPending(batch, entrant.id) then
      local spot = spots and spots[assignments[entrant.id]]
      if vehicleRow(entrant.id) or spot and not spot:hasAnyVehicles() then count = count + 1 end
    end
  end
  return math.min(budget or 0, count)
end

function M.isHeatReady(entrants)
  if not currentEvent then return false, 'The event paddock is preparing.' end
  if spawnFade then return false, 'Preparing the next group of event cars.' end
  if not parkedReady() then return false, 'Preparing the next group of event cars.' end
  if layout and not batchStarted and parkedCount() < initialTarget() then
    local ready, reason = M.canSpawn()
    return false, not ready and reason or 'Preparing the next group of event cars.'
  end
  for _, entrant in ipairs(entrants or {}) do
    if not entrant.player and not vehicleRow(entrant.id) then return M.canSpawn() end
  end
  return true
end

local function configPath(entrant)
  local config = entrant.config
  if not config:match('%.pc$') then config = config .. '.pc' end
  if not config:match('^vehicles/') then config = 'vehicles/' .. entrant.model .. '/' .. config end
  return config
end

local function spawnParked(entrant)
  local index = assignments[entrant.id]
  local spot = index and spots[index]
  if not spot or spot:hasAnyVehicles() then return nil end
  local vehicle = core_vehicles.spawnNewVehicle(entrant.model, {config = configPath(entrant),
    pos = spot.pos + vec3(0, 0, .2), rot = spot.rot, centeredPosition = true, safeSpawn = false, autoEnterVehicle = false})
  if not vehicle then return nil end
  local row = {id = vehicle:getID(), spot = index, initializing = true}
  parked[entrant.id] = row
  return row
end

local function initializeParked()
  for entrantId, row in pairs(parked) do
    if row.initializing then
      local vehicle = be:getObjectByID(row.id)
      if vehicle and row.id ~= be:getPlayerVehicleID(0) and (not vehicle.isReady or vehicle:isReady()) then
        local ok, err = pcall(function()
          vehicle:autoplace(false)
          vehicle:queueLuaCommand("extensions.load('ai'); ai:scriptStop(true, true); input.event('parkingbrake', 1, 2)")
        end)
        if not ok then vehicle:delete(); parked[entrantId] = nil; error(err, 0) end
        row.initializing = nil
      end
    end
  end
end

local function spawnGroup()
  if not parkedReady() then return false end
  for _, entrant in ipairs(candidates) do
    if parkedCount() >= initialTarget() then return true end
    if not entrant.player and assignments[entrant.id] and grid.isEntrantPending(batch, entrant.id)
      and not vehicleRow(entrant.id) and not leased[entrant.id] then
      local spot = spots[assignments[entrant.id]]
      if spot and not spot:hasAnyVehicles() then
        if not spawnParked(entrant) then error('Could not spawn ' .. entrant.name .. '.', 0) end
        return false
      end
    end
  end
  return true
end

local function updateSpawnFade(dt)
  spawnFade.age = spawnFade.age + dt
  if spawnFade.phase == 'reveal' then
    if spawnFade.age >= .4 then spawnFade = nil end
    return
  end
  if not M.canSpawn() then clearSpawnFade(); return end
  if spawnFade.phase == 'cover' and not ui_fadeScreen.isBlack() then
    if spawnFade.age > 5 then clearSpawnFade(); spawnClock = 3 end
    return
  end
  local ok, complete = pcall(spawnGroup)
  if not ok then
    clearSpawnFade(); spawnClock = 3
    toast(tostring(complete), 'bad', 8)
    return
  end
  if spawnFade.phase == 'cover' then
    spawnFade.phase, spawnFade.age = 'settle', 0
    return
  end
  if complete and parkedReady() and spawnFade.age >= .25 then
    ui_fadeScreen.stop(.4)
    spawnFade.phase, spawnFade.age = 'reveal', 0
  elseif spawnFade.age > 10 then
    clearSpawnFade(); spawnClock = 3
    toast('Group preparation is taking longer than expected.', 'warn', 8)
  end
end

function M.take(entrant, laneSpawn)
  if not currentEvent then return nil, 'The event paddock is unavailable.' end
  if spawnFade then return nil, 'Preparing the next group of event cars.' end
  local row = vehicleRow(entrant.id)
  if row then
    local vehicle = be:getObjectByID(row.id)
    if row.initializing or vehicle.isReady and not vehicle:isReady() then return nil, 'Preparing the next group of event cars.' end
    parked[entrant.id], leased[entrant.id], batchStarted = nil, row.id, true
    return row.id
  end
  local ready, reason = M.canSpawn()
  if not ready then return nil, reason end
  if not laneSpawn or not laneSpawn.pos or not laneSpawn.rot then return nil, 'The strip lane spawn is unavailable.' end
  local vehicle = core_vehicles.spawnNewVehicle(entrant.model, {config = configPath(entrant),
    pos = laneSpawn.pos, rot = laneSpawn.rot, autoEnterVehicle = false})
  if not vehicle then return nil, 'Could not spawn ' .. entrant.name .. '.' end
  vehicle:queueLuaCommand("extensions.load('ai'); ai:scriptStop(true, true); input.event('parkingbrake', 1, 2)")
  leased[entrant.id], batchStarted = vehicle:getID(), true
  return vehicle:getID(), nil, true
end

local function sessionKey(eventState)
    if eventState.spectatorQualifyingKey then return 'spectator:' .. eventState.spectatorQualifyingKey end
  local phase, classId = eventState.phase, eventState.activeClassId
  if phase == 'playerQualifying' or phase == 'qualifying' then
    phase = 'qualifying'
    if not classId then
      for _, row in ipairs(eventState.registrations or {}) do
        if (row.registrationId or row.id) == eventState.activeRegistrationId then classId = row.declaredClassId; break end
      end
    end
  end
  return phase .. ':' .. tostring(classId or eventState.activeRegistrationId or '') .. ':' .. tostring(eventState.bracket and eventState.bracket.currentRound or 0)
end

local function reconcileBatch(eventState)
  local byId, matches = {}, {}
  for _, entrant in ipairs(eventState.entrants or {}) do byId[entrant.id] = entrant end
  local round = eventState.bracket and eventState.bracket.rounds[eventState.bracket.currentRound]
  for _, match in ipairs(round and round.matches or {}) do
    if match.id then matches[match.id] = match end
  end
  for index, entrant in ipairs(candidates) do candidates[index] = byId[entrant.id] or entrant end
  for _, heat in ipairs(batch) do
    if heat.match and matches[heat.match.id] then heat.match = matches[heat.match.id] end
    for index, entrant in ipairs(heat.entrants) do heat.entrants[index] = byId[entrant.id] or entrant end
  end
end

local function upcomingPlayerGroup(eventState, playerPending)
  if not groupNumber or playerPending then return nil end
  local groups = grid.groups(eventState, groupRound)
  local nextGroup, round = groups[groupNumber + 1], nil
  if not nextGroup and not eventState.bracket and not eventState.roundRotation then
    local info = qualifying.roundInfo(eventState.entrants)
    if groupRound < info.maxRounds then
      round = groupRound + 1
      nextGroup = grid.groups(eventState, round)[1]
    end
  end
  for _, entrant in ipairs(nextGroup and nextGroup.entrants or {}) do
    if entrant.player and grid.isEntrantPending(nextGroup.heats, entrant.id) then
      return {group = nextGroup.number, round = round, entrantId = entrant.id}
    end
  end
end

function M.update(eventState, dtSim, playerPass, dtReal)
  if not eventState then M.stop(); return end
  local key = sessionKey(eventState)
  if currentEvent ~= eventState.id or gridKey ~= key then begin(eventState, key) end
  reconcileBatch(eventState)
  if playerPass and not playerDispatched then
    playerDispatched = true
    clearPlayerRoute()
    gameplay_rawPois.clear()
  end
  updateStationary(dtSim)
  budget = layout and math.min(M.getBudget(), #spots, 6) or 0
  local activeCount = 0
  for entrantId, id in pairs(leased) do
    if be:getObjectByID(id) then activeCount = activeCount + 1 else leased[entrantId] = nil end
  end
  if playerDispatched and not playerPass and activeCount == 0 then
    for _, entrant in ipairs(candidates) do
      if entrant.player and grid.isEntrantPending(batch, entrant.id) then
        playerDispatched, playerNotified, batchStarted, groupPrepared = false, false, false, false
        spawnClock = 0
        gameplay_rawPois.clear()
        break
      end
    end
  end
  local count = parkedCount()
  while count > math.max(0, budget - activeCount) do
    local selected, highest = nil, -1
    for id, row in pairs(parked) do if row.spot > highest then selected, highest = id, row.spot end end
    local row = selected and parked[selected]
    if not row then break end
    local vehicle = be:getObjectByID(row.id)
    if vehicle and row.id ~= be:getPlayerVehicleID(0) then vehicle:delete() end
    parked[selected], count = nil, count - 1
  end
  if grid.batchFinished(batch) and activeCount == 0 then beginBatch(eventState); count = 0 end
  local initialized, err = pcall(initializeParked)
  if not initialized then
    clearSpawnFade(); spawnClock = 3
    toast(tostring(err), 'bad', 8)
    return
  end
  if spawnFade then updateSpawnFade(math.max(0, dtReal or dtSim or 0)); return end
  if not groupPrepared and count >= initialTarget() and parkedReady() then groupPrepared = true end
  local playerSpot = M.getPlayerSpot(eventState)
  local playerPending = false
  for _, entrant in ipairs(candidates) do
    if entrant.player and grid.isEntrantPending(batch, entrant.id) then playerPending = true; break end
  end
  if upcomingChecked ~= playerPending then playerUpcoming, upcomingChecked = upcomingPlayerGroup(eventState, playerPending), playerPending end
  if playerSpot then playerUpcoming = nil end
  if playerUpcoming then
    local notice = gridKey .. ':' .. tostring(playerUpcoming.round or qualifying.roundInfo(eventState.entrants).number) .. ':' .. playerUpcoming.group .. ':' .. playerUpcoming.entrantId
    if upcomingNotified ~= notice then
      upcomingNotified = notice
      toast("You're up next. Get your car ready" .. (playerUpcoming.round and ' for round ' .. playerUpcoming.round or '') .. '.', 'warn', 10)
    end
  end
  if playerSpot and not playerNotified then
    playerNotified = true
    toast('Go to ' .. M.spotLabel(playerSpot) .. '. Group ' .. groupNumber .. '/' .. groupCount .. ' is up.', 'warn', 10)
    M.routePlayer(eventState)
    gameplay_rawPois.clear()
  elseif not playerSpot then clearPlayerRoute() end
  if not layout or batchStarted or not M.canSpawn() or count >= initialTarget() or not parkedReady() then return end
  spawnClock = math.max(0, (spawnClock or 0) - math.max(0, dtReal or dtSim or 0))
  if spawnClock > 0 then return end
  if ui_fadeScreen and ui_fadeScreen.start and ui_fadeScreen.stop and ui_fadeScreen.isBlack then
    if ui_fadeScreen.isBlack() then return end
    spawnFade = {phase = 'cover', age = 0}
    ui_fadeScreen.start(.4)
  else
    local ok, err = pcall(spawnGroup)
    if not ok then
      spawnClock = 3
      if ui_message then ui_message(tostring(err), 8, 'motorsport') end
    end
  end
end

function M.getPlayerSpot(eventState)
  if not eventState or eventState.id ~= currentEvent or not layout or not groupPrepared or playerDispatched or spawnFade then return nil end
  for _, entrant in ipairs(candidates) do
    if entrant.player and grid.isEntrantPending(batch, entrant.id) then return spots[assignments[entrant.id]] end
  end
end
function M.routePlayer(eventState)
  local spot = M.getPlayerSpot(eventState)
  if not spot or not core_groundMarkers then return false end
  if routeToken ~= nil then
    return core_groundMarkers.getPathGeneration ~= nil and core_groundMarkers.getPathGeneration() == routeToken
  end
  routeToken = core_groundMarkers.setPath(spot.pos, {clearPathOnReachingTarget = true})
  return true
end
function M.getSide(entrantId)
  local index = assignments[entrantId]
  local spot = index and spots and spots[index]
  local number = spot and spot.name:match('^[A-Za-z]+([12])_')
  return number == '1' and 'left' or number == '2' and 'right' or nil
end
function M.getLayout() return layout end
function M.claimedHeats(eventState)
  if not eventState or eventState.id ~= currentEvent or gridKey ~= sessionKey(eventState) then return {} end
  local heats = {}
  for _, heat in ipairs(batch) do
    if not grid.heatFinished(heat) then
      local ids = {}
      for _, entrant in ipairs(heat.entrants) do ids[#ids + 1] = entrant.id end
      heats[#heats + 1] = ids
    end
  end
  return heats
end
function M.nextPair(eventState, skipPlayer)
  if eventState and eventState.id ~= currentEvent then return nil end
  return grid.nextPair(batch, skipPlayer)
end
function M.previewNext(eventState, inFlight, skipPlayer)
  if not eventState or not inFlight or eventState.id ~= currentEvent or gridKey ~= sessionKey(eventState) then return nil end
  local current
  for _, heat in ipairs(batch) do
    if heat.match and heat.match.id == inFlight then current = heat end
    for _, entrant in ipairs(heat.entrants) do if entrant.id == inFlight then current = heat end end
  end
  if not current then return nil end
  for _, heat in ipairs(batch) do
    if heat ~= current then
      local pair = grid.nextPair({heat}, skipPlayer)
      if pair then
        local ids = {}
        for _, entrant in ipairs(pair) do ids[#ids + 1] = entrant.id end
        return ids
      end
    end
  end
end
function M.isPlayerReady(eventState)
  local stopped, vehicle = playerStopped()
  local spot = M.getPlayerSpot(eventState)
  for _, entrant in ipairs(eventState.entrants or {}) do
    if entrant.player then
      return stopped == true and roster.matchesVehicle(entrant, vehicle)
        and (not layout or spot ~= nil and spot:checkParking(vehicle:getID(), .5, .5, .5))
    end
  end
  return false
end
function M.getVehicleId(entrantId) return leased[entrantId] or parked[entrantId] and parked[entrantId].id end
function M.status()
  local playerSpot, nextEntrantIds, groupEntrantIds = nil, {}, {}
  for _, entrant in ipairs(grid.nextPair(batch) or {}) do nextEntrantIds[#nextEntrantIds + 1] = entrant.id end
  for _, entrant in ipairs(candidates) do groupEntrantIds[#groupEntrantIds + 1] = entrant.id end
  if layout and groupPrepared and not playerDispatched and not spawnFade then
    for _, entrant in ipairs(candidates) do
      if entrant.player and grid.isEntrantPending(batch, entrant.id) then playerSpot = spots[assignments[entrant.id]]; break end
    end
  end
  return {parked = parkedCount(), capacity = budget or 0, groupNumber = groupNumber, groupCount = groupCount or 0,
    playerCalled = playerSpot ~= nil, playerSpotName = playerSpot and M.spotLabel(playerSpot),
    playerUpcoming = playerUpcoming ~= nil, upcomingGroupNumber = playerUpcoming and playerUpcoming.group,
    upcomingRound = playerUpcoming and playerUpcoming.round,
    preparing = groupNumber ~= nil and (not groupPrepared or spawnFade ~= nil), nextEntrantIds = nextEntrantIds, groupEntrantIds = groupEntrantIds}
end

return M
