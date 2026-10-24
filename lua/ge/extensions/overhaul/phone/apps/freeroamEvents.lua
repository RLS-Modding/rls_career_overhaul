-- Phone lists for races, burnout and demolition events, vehicle records and navigation.
-- Read level data, event projections, navigation and public commands, then lifecycle hooks.
local raceDataCatalog = require('overhaul/lib/events/raceDataCatalog')
local M = {}
local context = require('overhaul/lib/career/context')

local capabilities = require('overhaul/lib/platform/capabilities')
local raceScoring = require('overhaul/lib/events/raceScoring')
local burnoutConfig = require('overhaul/lib/events/burnoutConfig')
local pullingConfig = require('overhaul/lib/events/pullingConfig')
local eventHelpers = require('overhaul/lib/events/helpers')
local eventArtwork = require('overhaul/lib/events/artwork')

-- Config ------------------------------------------------------------------------------------------

local LOG_TAG = 'overhaul_phone_apps_freeroamEvents'
local DEFAULT_BURNOUT_SCORE_GOAL = 6000
local DEFAULT_DRIFT_TARGET_SECONDS = 60
local DEMO_TYPE_ALIASES = { demo = true, demolition = true, demolitionderby = true }

-- State -------------------------------------------------------------------------------------------

-- Navigation targets by event id, rebuilt on every events refresh.
local navTargets = {}

local getCurrentLevel = context.currentLevel
local isCareerActive = context.isCareerActive

-- Reloads and provider replacement must be visible to the next records request.
local function getRaceRecordEntry(inventoryId, raceLabel)
  local records = capabilities.get('raceRecords')
  return records and records.getLeaderboardEntry(inventoryId, raceLabel)
end

-- Level files ------------------------------------------------------------------------------------

local function loadRaceData()
  local level = getCurrentLevel()
  if not level or level == '' then
    log('D', LOG_TAG, 'loadRaceData: no level identifier')
    return {}
  end
  local filePath = 'levels/' .. level .. '/race_data.json'
  local raceData = raceDataCatalog.read(filePath)
  local fromFile = raceData ~= nil
  raceData = raceData or { races = {} }
  local races = raceData.races or {}
  local count = 0
  for _ in pairs(races) do count = count + 1 end
  log('D', LOG_TAG, string.format('loadRaceData: path=%s, fileRead=%s, races=%d', filePath, tostring(fromFile), count))
  return races
end

local function loadLevelTable(level, fileName)
  if not level or level == '' then return nil end
  local data = jsonReadFile('levels/' .. level .. '/' .. fileName)
  if type(data) ~= 'table' then return nil end
  return data
end

local function getPlayerPos()
  local veh = getPlayerVehicle(0)
  if veh then return veh:getPosition() end
  return nil
end

local function getDistanceFromPlayer(playerPos, worldPos)
  if not playerPos or not worldPos then return -1 end
  return math.floor((worldPos - playerPos):length())
end

local function getZoneByName(sitesData, zoneName)
  if type(zoneName) ~= 'string' or zoneName == '' then return nil end
  if type(sitesData) ~= 'table' or type(sitesData.zones) ~= 'table' then return nil end
  for _, zone in ipairs(sitesData.zones) do
    if type(zone) == 'table' and zone.name == zoneName then return zone end
  end
  return nil
end

local function getZoneCentroid(zone)
  if type(zone) ~= 'table' or type(zone.vertices) ~= 'table' or #zone.vertices < 3 then return nil end
  local sx, sy, sz = 0, 0, 0
  local count = 0
  for _, vertex in ipairs(zone.vertices) do
    if type(vertex) == 'table' then
      sx = sx + (tonumber(vertex[1]) or 0)
      sy = sy + (tonumber(vertex[2]) or 0)
      sz = sz + (tonumber(vertex[3]) or 0)
      count = count + 1
    end
  end
  if count <= 0 then return nil end
  return vec3(sx / count, sy / count, sz / count)
end

local function getParkingSpotByName(sitesData, spotName)
  if type(spotName) ~= 'string' or spotName == '' then return nil end
  if type(sitesData) ~= 'table' or type(sitesData.parkingSpots) ~= 'table' then return nil end
  for _, spot in ipairs(sitesData.parkingSpots) do
    if type(spot) == 'table' and spot.name == spotName then return spot end
  end
  return nil
end

local function loadPullingData(levelId, eventId)
  local raw = loadLevelTable(levelId, 'overhaul/pulling.json')
  if not raw then return nil end
  local event = pullingConfig.getEvent(raw, eventId)
  if not event then return nil end
  local config = pullingConfig.normalize(event)
  if not config.sitesFile or not config.stagingSpot or not config.spawnSpot then
    log('W', LOG_TAG, 'Pulling event unavailable: missing configured sites or location bindings for ' .. eventId)
    return nil
  end
  return config, loadLevelTable(levelId, config.sitesFile)
end

-- Length of the configured track, or nil when authored endpoints are missing.
local function getPullTrackDistance(levelId, eventId)
  local config, sites = loadPullingData(levelId, eventId)
  if not config then return nil end
  local spawnSpot = getParkingSpotByName(sites, config.spawnSpot)
  local finishSpot = getParkingSpotByName(sites, config.finishSpot)
  if not spawnSpot or not finishSpot then return nil end
  local startPos, finishPos = spawnSpot.pos, finishSpot.pos
  if type(startPos) ~= 'table' or type(finishPos) ~= 'table' then return nil end
  for i = 1, 3 do
    if type(startPos[i]) ~= 'number' or type(finishPos[i]) ~= 'number' then return nil end
  end
  local distance = (vec3(finishPos[1], finishPos[2], finishPos[3]) - vec3(startPos[1], startPos[2], startPos[3])):length()
  return distance > 1 and distance or nil
end

-- Where a demo event starts: its configured spot, then the scene objects, then its play zone.
local function findDemoEventWorldPos(eventKey, eventCfg, sitesData)
  local spotName = type(eventCfg) == 'table' and eventCfg.startSpotName or nil
  if type(spotName) ~= 'string' or spotName == '' then
    spotName = 'start_' .. tostring(eventKey or '')
  end
  local startSpot = getParkingSpotByName(sitesData, spotName)
  if type(startSpot) == 'table' and type(startSpot.pos) == 'table' then
    local x = tonumber(startSpot.pos[1])
    local y = tonumber(startSpot.pos[2])
    local z = tonumber(startSpot.pos[3])
    if x and y and z then return vec3(x, y, z) end
  end

  local startObj = scenetree.findObject('fre_start_' .. eventKey)
  if startObj then return startObj:getPosition() end

  local stagingObj = scenetree.findObject('fre_staging_' .. eventKey)
  if stagingObj then return stagingObj:getPosition() end

  local suffix = tostring(eventKey):match('^demo_(.+)$')
  if suffix then
    local suffixStagingObj = scenetree.findObject('fre_staging_demo_' .. suffix)
    if suffixStagingObj then return suffixStagingObj:getPosition() end
  end

  local zoneName = type(eventCfg) == 'table' and eventCfg.playZone or nil
  return getZoneCentroid(getZoneByName(sitesData, zoneName))
end

-- Burnout events ----------------------------------------------------------------------------------

local function decorateBurnoutEventForUi(event, level)
  local out = {}
  for key, value in pairs(event) do out[key] = value end
  out.thumbnail = eventArtwork.resolve(level, event.eventId, event.thumbnail)
  return out
end

local function loadBurnoutConfigAndSites(level)
  local data = burnoutConfig.loadLevelData(level)
  local events = {}
  for _, event in ipairs(data.events or {}) do
    table.insert(events, decorateBurnoutEventForUi(event, level))
  end
  return events, data.sites
end

local function getBurnoutDefinitions(levelId)
  return loadBurnoutConfigAndSites(levelId)
end

local function getBurnoutDefinitionByEventId(eventId, levelId)
  for _, event in ipairs(getBurnoutDefinitions(levelId or getCurrentLevel() or '')) do
    if event.eventId == eventId then return event end
  end
  return nil
end

local function jobMarketMultiplier()
  if not overhaul_career_economy_globalEconomy then return 1.0 end
  local index = overhaul_career_economy_globalEconomy.getJobMarketIndex()
  if type(index) ~= 'number' then return 1.0 end
  return index
end

local function burnoutMultiplier(raceTypes)
  if not overhaul_career_career.isActive() or not overhaul_career_economyAdjuster
      or not raceTypes or #raceTypes == 0 then return 1.0 end
  local total, count = 0, 0
  for _, raceType in ipairs(raceTypes) do
    local multiplier = overhaul_career_economyAdjuster.getEffectiveSectionMultiplier({raceType})
    if multiplier > 0 then total, count = total + multiplier, count + 1 end
  end
  local average = count > 0 and total / count or 0
  if average == 0 then return 0 end
  return average * jobMarketMultiplier()
end

-- Keep the scoring library pure; the phone supplies the same live career economy policy.
local function displayMultiplier(raceTypes)
  if overhaul_career_career.isActive() and overhaul_career_economyAdjuster then
    return burnoutMultiplier(raceTypes)
  end
  return 1
end

-- Burnout reward for the player: the drift reward when the career runs, the listed reward otherwise.
local function getBurnoutDisplayReward(burnoutEvent)
  local baseReward = tonumber(burnoutEvent.reward) or 0
  if not overhaul_career_career.isActive() then
    return baseReward
  end
  local scoreGoal = tonumber(burnoutEvent.scoreGoal or burnoutEvent.driftGoal) or DEFAULT_BURNOUT_SCORE_GOAL
  local driftTargetTime = tonumber(burnoutEvent.driftTargetTime) or DEFAULT_DRIFT_TARGET_SECONDS
  local bestTime = tonumber(burnoutEvent.bestTime) or driftTargetTime
  if driftTargetTime <= 0 then driftTargetTime = DEFAULT_DRIFT_TARGET_SECONDS end
  if bestTime <= 0 then bestTime = DEFAULT_DRIFT_TARGET_SECONDS end
  local raceStub = {
    label = burnoutEvent.label,
    type = burnoutEvent.types,
    burnoutComp = true,
    driftGoal = scoreGoal,
    driftTargetTime = driftTargetTime,
    bestTime = bestTime,
    reward = baseReward,
  }
  local multiplierFor = raceStub.type and displayMultiplier or nil
  return math.floor((raceScoring.driftReward(raceStub, bestTime, scoreGoal, multiplierFor) or baseReward) + 0.5)
end

-- Where a burnout event is: its trigger object first, then its zone's centre.
local function burnoutPosition(burnoutEvent, sites)
  if burnoutEvent.triggerName then
    local startObj = scenetree.findObject(burnoutEvent.triggerName)
    if startObj then
      local objPos = startObj:getPosition()
      return { x = objPos.x, y = objPos.y, z = objPos.z }, objPos
    end
  end
  if burnoutEvent.zoneName then
    local zonePos = getZoneCentroid(getZoneByName(sites, burnoutEvent.zoneName))
    if zonePos then return { x = zonePos.x, y = zonePos.y, z = zonePos.z }, zonePos end
  end
  return nil, nil
end

-- Vehicle records ---------------------------------------------------------------------------------

local function getVehicleDisplayName(vehData)
  if not vehData then return 'Unknown Vehicle' end
  local name = ''
  if vehData.niceName then
    name = vehData.niceName
  elseif vehData.model then
    name = vehData.model
  end
  if vehData.configName and vehData.configName ~= '' then
    name = name .. ' ' .. vehData.configName
  end
  return name ~= '' and name or 'Unknown Vehicle'
end

local function normalizeTypeToken(value)
  if type(value) ~= 'string' then return nil end
  return string.lower(value)
end

local function hasType(types, expected)
  if type(types) ~= 'table' then return false end
  local expectedNorm = normalizeTypeToken(expected)
  if not expectedNorm then return false end
  local expectedIsDemo = DEMO_TYPE_ALIASES[expectedNorm] == true
  for _, typeName in ipairs(types) do
    local token = normalizeTypeToken(typeName)
    if token == expectedNorm then return true end
    if expectedIsDemo and DEMO_TYPE_ALIASES[token] then return true end
  end
  return false
end

local function buildDemoStatsFromEntry(entry)
  entry = type(entry) == 'table' and entry or {}
  return {
    runs = math.max(0, math.floor(tonumber(entry.demoRuns) or 0)),
    wins = math.max(0, math.floor(tonumber(entry.demoWins) or 0)),
    podiums = math.max(0, math.floor(tonumber(entry.demoPodiums) or 0)),
    averagePlacement = tonumber(entry.demoAveragePlacement) or 0,
    podiumRate = tonumber(entry.demoPodiumRate) or 0,
    fastestEliminationTime = tonumber(entry.demoFastestEliminationTime) or nil,
    averageSurvivalTime = tonumber(entry.demoAverageSurvivalTime) or 0,
    longestSurvivalTime = tonumber(entry.demoLongestSurvivalTime) or 0,
  }
end

local function hasDemoStats(stats)
  return type(stats) == 'table' and math.max(0, math.floor(tonumber(stats.runs) or 0)) > 0
end

-- Demo records rank by wins, then podium rate, then average placement, then name.
local function sortDemoRecords(records)
  table.sort(records, function(a, b)
    local sa = a.demoStats or {}
    local sb = b.demoStats or {}
    local winsA, winsB = tonumber(sa.wins) or 0, tonumber(sb.wins) or 0
    if winsA ~= winsB then return winsA > winsB end
    local podiumA, podiumB = tonumber(sa.podiumRate) or 0, tonumber(sb.podiumRate) or 0
    if podiumA ~= podiumB then return podiumA > podiumB end
    local placeA, placeB = tonumber(sa.averagePlacement) or math.huge, tonumber(sb.averagePlacement) or math.huge
    if placeA ~= placeB then return placeA < placeB end
    return tostring(a.vehicleName or '') < tostring(b.vehicleName or '')
  end)
end

local function sortTimedRecords(records)
  table.sort(records, function(a, b)
    if a.time and b.time then return a.time < b.time end
    if a.time then return true end
    return false
  end)
end

local function collectVehicleRecordsForLabel(allVehicles, raceLabel, isDemoEvent)
  local vehicleRecords = {}
  for invId, vehData in pairs(allVehicles or {}) do
    local entry = getRaceRecordEntry(invId, raceLabel) or {}
    local demoStats = buildDemoStatsFromEntry(entry)
    if entry.time or entry.driftScore or entry.topSpeed or (isDemoEvent and hasDemoStats(demoStats)) then
      table.insert(vehicleRecords, {
        inventoryId = invId,
        vehicleName = getVehicleDisplayName(vehData),
        time = entry.time,
        driftScore = entry.driftScore,
        scoreMode = entry.scoreMode,
        topSpeed = entry.topSpeed,
        damagePercentage = entry.damagePercentage,
        demoStats = demoStats,
      })
    end
  end
  if isDemoEvent then
    sortDemoRecords(vehicleRecords)
  else
    sortTimedRecords(vehicleRecords)
  end
  return vehicleRecords
end

local function buildVehicleRecords(allVehicles, eventLabel)
  local vehicleRecords = {}
  for invId, vehData in pairs(allVehicles or {}) do
    local entry = getRaceRecordEntry(invId, eventLabel) or {}
    if entry.time or entry.driftScore or entry.topSpeed then
      table.insert(vehicleRecords, {
        inventoryId = invId,
        vehicleName = getVehicleDisplayName(vehData),
        time = entry.time,
        driftScore = entry.driftScore,
        scoreMode = entry.scoreMode,
        topSpeed = entry.topSpeed,
        damagePercentage = entry.damagePercentage,
      })
    end
  end

  table.sort(vehicleRecords, function(a, b)
    if a.driftScore and b.driftScore then return a.driftScore > b.driftScore end
    if a.driftScore then return true end
    if b.driftScore then return false end
    if a.topSpeed and b.topSpeed then return a.topSpeed > b.topSpeed end
    if a.topSpeed then return true end
    if b.topSpeed then return false end
    if a.time and b.time then return a.time < b.time end
    if a.time then return true end
    return false
  end)
  return vehicleRecords
end

-- Tractor pulls rank by full pulls, then distance, then time.
local function buildPullVehicleRecords(allVehicles, race)
  local records = {}
  local baseLabel = race.label or 'Tractor Pull'
  for _, sled in ipairs(type(race.sledPresets) == 'table' and race.sledPresets or {}) do
    local label = baseLabel .. ' - ' .. tostring(sled.label or sled.id)
    for invId, vehData in pairs(allVehicles or {}) do
      local entry = getRaceRecordEntry(invId, label) or {}
      if tonumber(entry.pullDistance) then
        records[#records + 1] = {
          inventoryId = invId,
          vehicleName = getVehicleDisplayName(vehData),
          time = entry.time,
          pullDistance = entry.pullDistance,
          fullPull = entry.fullPull == true,
          sledId = entry.sledId or sled.id,
          sledLabel = sled.label or sled.id,
        }
      end
    end
  end
  table.sort(records, function(a, b)
    if a.fullPull ~= b.fullPull then return a.fullPull end
    local distanceA, distanceB = tonumber(a.pullDistance) or 0, tonumber(b.pullDistance) or 0
    if math.abs(distanceA - distanceB) > 0.001 then return distanceA > distanceB end
    return (tonumber(a.time) or math.huge) < (tonumber(b.time) or math.huge)
  end)
  return records
end

-- Race events ------------------------------------------------------------------------------------

-- Sets the fields a race or demo does not carry, so a refresh clears what the last one set.
local function clearRaceOnlyFields(event)
  event.bestTime = nil
  event.hotlap = false
  event.hasDamageFactor = false
  event.damageFactor = 0
  event.hasTopSpeed = false
  event.topSpeedGoal = nil
  event.hasDrift = false
  event.driftGoal = nil
  event.scoreMode = false
  event.scoreGoal = nil
  event.currentVehicleBestScore = nil
  event.hasAltRoute = false
  event.altRouteLabel = nil
  event.altRouteBestTime = nil
  event.altRouteReward = nil
end

-- A tractor pull without a scene object is placed at its staging spot.
local function pullStagingPosition(levelId, raceName, playerPos)
  local config, pullingSites = loadPullingData(levelId, raceName)
  if not config then return nil, -1 end
  local pullStaging = getParkingSpotByName(pullingSites, config.stagingSpot)
  local spotPos = pullStaging and pullStaging.pos or nil
  if type(spotPos) ~= 'table' then return nil, -1 end
  for i = 1, 3 do if type(spotPos[i]) ~= 'number' then return nil, -1 end end
  local worldPos = vec3(spotPos[1], spotPos[2], spotPos[3])
  navTargets[raceName] = worldPos
  return { x = worldPos.x, y = worldPos.y, z = worldPos.z }, getDistanceFromPlayer(playerPos, worldPos)
end

-- Demo events -------------------------------------------------------------------------------------

-- Demo fields that come from the demo config (merged over the config's defaults).
local function demoEventFields(eventKey, merged, playerPos, levelId, demoSites, allVehicles, currentVehicle)
  local label = merged.label or eventKey
  local worldPos = findDemoEventWorldPos(eventKey, merged, demoSites)
  local pos = nil
  local distance = -1
  if worldPos then
    pos = { x = worldPos.x, y = worldPos.y, z = worldPos.z }
    distance = getDistanceFromPlayer(playerPos, worldPos)
    navTargets[eventKey] = vec3(worldPos.x, worldPos.y, worldPos.z)
  end

  local bestTime = nil
  local bestDemoStats = nil
  if currentVehicle.id then
    local bestEntry = getRaceRecordEntry(currentVehicle.id, label) or {}
    bestTime = bestEntry.time
    bestDemoStats = buildDemoStatsFromEntry(bestEntry)
  end

  local types = merged.type
  if type(types) ~= 'table' or #types == 0 then types = { 'demo' } end
  local isDemoEvent = hasType(types, 'demo')
  return {
    label = label,
    types = types,
    isDemoEvent = isDemoEvent,
    reward = tonumber(merged.reward) or 0,
    hasWorldPos = worldPos ~= nil,
    position = pos,
    distance = distance,
    thumbnail = eventArtwork.resolve(levelId, eventKey, merged.thumbnail),
    currentVehicleBestTime = bestTime,
    demoStats = bestDemoStats,
    currentVehicleName = currentVehicle.name,
    vehicleRecords = collectVehicleRecordsForLabel(allVehicles, label, isDemoEvent),
  }
end

-- A demo can share an id with a race; the race keeps its own fields, and the demo fills in the rest.
local function mergeDemoIntoExisting(existing, fields)
  existing.label = existing.label or fields.label
  existing.types = fields.types
  existing.isDemoEvent = fields.isDemoEvent
  existing.reward = existing.reward or fields.reward
  clearRaceOnlyFields(existing)
  existing.position = existing.position or fields.position
  if existing.position and (existing.distance == nil or existing.distance < 0) and fields.hasWorldPos then
    existing.distance = fields.distance
  elseif existing.distance == nil then
    existing.distance = fields.distance
  end
  existing.thumbnail = existing.thumbnail or fields.thumbnail
  existing.currentVehicleBestTime = fields.currentVehicleBestTime
  existing.demoStats = fields.demoStats
  existing.currentVehicleName = fields.currentVehicleName
  existing.vehicleRecords = fields.vehicleRecords
end

local function newDemoEvent(eventKey, fields)
  local event = {
    raceName = eventKey,
    label = fields.label,
    types = fields.types,
    isDemoEvent = fields.isDemoEvent,
    reward = fields.reward,
    position = fields.position,
    distance = fields.distance,
    thumbnail = fields.thumbnail,
    currentVehicleBestTime = fields.currentVehicleBestTime,
    demoStats = fields.demoStats,
    currentVehicleName = fields.currentVehicleName,
    vehicleRecords = fields.vehicleRecords,
  }
  clearRaceOnlyFields(event)
  return event
end

local function appendDemoEvents(events, levelId, playerPos, allVehicles, currentVehicle)
  local derby = overhaul_events_derby_derby
  if not derby then return end
  for _, eventKey in ipairs(derby.getAvailableEventKeys()) do
    local merged, demoSites = derby.getEventLocation(eventKey)
    if merged then
      local fields = demoEventFields(eventKey, merged, playerPos, levelId, demoSites, allVehicles, currentVehicle)
      local existing = events[eventKey]
      if existing then
        mergeDemoIntoExisting(existing, fields)
      else
        events[eventKey] = newDemoEvent(eventKey, fields)
      end
    end
  end
end

-- Burnout and events list ------------------------------------------------------------------------

local function addBurnoutEvents(events, levelId, currentVehicle, allVehicles, playerPos)
  local _, sites = loadBurnoutConfigAndSites(levelId)
  for _, burnoutEvent in ipairs(getBurnoutDefinitions(levelId)) do
    local pos, posVec = burnoutPosition(burnoutEvent, sites)
    local distance = -1
    if posVec and playerPos then distance = math.floor((posVec - playerPos):length()) end
    if pos then navTargets[burnoutEvent.eventId] = vec3(pos.x, pos.y, pos.z) end

    local currentVehicleBestEntry = {}
    if currentVehicle.id then
      currentVehicleBestEntry = getRaceRecordEntry(currentVehicle.id, burnoutEvent.label) or {}
    end

    events[burnoutEvent.eventId] = {
      raceName = burnoutEvent.eventId,
      label = burnoutEvent.label,
      types = burnoutEvent.types,
      reward = getBurnoutDisplayReward(burnoutEvent),
      baseReward = burnoutEvent.reward,
      hasDamageFactor = false,
      damageFactor = 0,
      hasTopSpeed = false,
      hasDrift = false,
      hasBurnout = true,
      scoreMode = true,
      isOpenScore = true,
      scoreGoal = burnoutEvent.scoreGoal,
      hasAltRoute = false,
      position = pos,
      distance = distance,
      thumbnail = burnoutEvent.thumbnail,
      currentVehicleBestTime = currentVehicleBestEntry.time,
      currentVehicleBestScore = currentVehicleBestEntry.driftScore,
      currentVehicleName = currentVehicle.name,
      vehicleRecords = buildVehicleRecords(allVehicles, burnoutEvent.label),
    }
  end
end

local function currentVehicleAndFleet(careerActive)
  local inventory = careerActive and overhaul_career_garage_inventory
  local current = { id = nil, name = 'No Vehicle' }
  local playerVehId = be:getPlayerVehicleID(0)
  if playerVehId and playerVehId >= 0 then
    current.name = 'Current Vehicle'
    if inventory and inventory.getInventoryIdFromVehicleId then
      current.id = inventory.getInventoryIdFromVehicleId(playerVehId)
    end
  end
  local fleet = {}
  if inventory and inventory.getVehicles then
    fleet = inventory.getVehicles() or {}
  end
  if current.id and fleet[current.id] then
    current.name = getVehicleDisplayName(fleet[current.id])
  end
  return current, fleet
end

local function eventSceneObject(raceName, race)
  for _, role in ipairs({'start', 'staging'}) do
    for _, name in ipairs(eventHelpers.sceneTriggerNames(raceName, race, role)) do
      local object = scenetree.findObject(name)
      if object then return object end
    end
  end
end

local function racePosition(levelId, raceName, race, isPulling, playerPos)
  if isPulling then return pullStagingPosition(levelId, raceName, playerPos) end
  local startObj = eventSceneObject(raceName, race)
  if startObj then
    local objPos = startObj:getPosition()
    navTargets[raceName] = vec3(objPos.x, objPos.y, objPos.z)
    local distance = -1
    if playerPos then distance = math.floor((objPos - playerPos):length()) end
    return { x = objPos.x, y = objPos.y, z = objPos.z }, distance
  end
  return nil, -1
end

local function currentVehicleRaceBest(currentVehicleId, race, fleet, isPulling)
  if not currentVehicleId then return nil, nil, nil end
  local entry = getRaceRecordEntry(currentVehicleId, race.label) or {}
  if not isPulling then return entry.time, nil, entry.driftScore end
  local bestPullDistance = nil
  for _, record in ipairs(buildPullVehicleRecords({ [currentVehicleId] = fleet[currentVehicleId] }, race)) do
    bestPullDistance = math.max(bestPullDistance or 0, tonumber(record.pullDistance) or 0)
  end
  return nil, bestPullDistance
end

local function raceEvent(levelId, raceName, race, playerPos, currentVehicle, fleet)
  local isPulling = hasType(race.type, 'pulling')
  local pos, distance = racePosition(levelId, raceName, race, isPulling, playerPos)
  if isPulling and not pos then
    log('D', LOG_TAG, 'Pulling event disabled: no configured staging location for ' .. raceName)
    return nil
  end
  local bestTime, bestPullDistance, bestScore = currentVehicleRaceBest(currentVehicle.id, race, fleet, isPulling)
  return {
    raceName = raceName,
    label = race.label or raceName,
    types = race.type or {},
    bestTime = race.bestTime,
    reward = race.reward,
    hotlap = race.hotlap,
    hasDamageFactor = (race.damageFactor ~= nil and race.damageFactor > 0),
    damageFactor = race.damageFactor or 0,
    hasTopSpeed = (race.topSpeed ~= nil and race.topSpeed ~= false),
    topSpeedGoal = race.topSpeedGoal,
    hasDrift = (race.driftGoal ~= nil),
    scoreMode = race.scoreMode == true or race.driftGoal ~= nil or race.burnoutComp == true,
    scoreGoal = race.scoreGoal,
    driftGoal = race.driftGoal,
    hasAltRoute = (race.altRoute ~= nil),
    isPulling = isPulling,
    pullDistanceMeters = isPulling and (getPullTrackDistance(levelId, raceName) or tonumber(race.pullDistanceMeters)) or nil,
    altRouteLabel = race.altRoute and race.altRoute.label,
    altRouteBestTime = race.altRoute and race.altRoute.bestTime,
    altRouteReward = race.altRoute and race.altRoute.reward,
    position = pos,
    distance = distance,
    thumbnail = eventArtwork.resolve(levelId, raceName, race.thumbnail),
    currentVehicleBestTime = bestTime,
    currentVehicleBestScore = bestScore,
    currentVehicleBestPullDistance = bestPullDistance,
    currentVehicleName = currentVehicle.name,
    vehicleRecords = isPulling and buildPullVehicleRecords(fleet, race)
      or buildVehicleRecords(fleet, race.label),
  }
end

local function buildEventsData()
  log('D', LOG_TAG, 'buildEventsData: called')
  local careerActive = isCareerActive() == true




  local levelId = getCurrentLevel()
  if not levelId or levelId == '' then
    local missionFilename = getMissionFilename and getMissionFilename() or ''
    log('D', LOG_TAG, string.format('buildEventsData: no levelId (mission=%s)', tostring(missionFilename)))
    return { events = {}, careerActive = careerActive, levelId = '' }
  end
  log('D', LOG_TAG, string.format('buildEventsData: levelId=%s', levelId))

  local races = loadRaceData()
  if not races or not next(races) then
    log('D', LOG_TAG, 'buildEventsData: no races found')
    races = {}
  end

  local currentVehicle, fleet = currentVehicleAndFleet(careerActive)
  local playerPos = getPlayerPos()

  navTargets = {}
  local events = {}
  for raceName, race in pairs(races) do
    events[raceName] = raceEvent(levelId, raceName, race, playerPos, currentVehicle, fleet)
  end

  addBurnoutEvents(events, levelId, currentVehicle, fleet, playerPos)
  appendDemoEvents(events, levelId, playerPos, fleet, currentVehicle)

  if not next(events) then
    log('D', LOG_TAG, 'buildEventsData: no race_data or demo events found')
    return { events = {}, careerActive = careerActive, levelId = levelId }
  end

  local eventCount = 0
  for _ in pairs(events) do eventCount = eventCount + 1 end
  log('D', LOG_TAG, string.format('buildEventsData: built %d events', eventCount))
  local payload = {
    events = events,
    careerActive = careerActive,
    currentVehicleId = currentVehicle.id,
    currentVehicleName = currentVehicle.name,
    levelId = levelId,
  }
  return payload
end

local function getEventsData()
  guihooks.trigger('phoneFreeroamEventsData', buildEventsData())
end

-- Public API --------------------------------------------------------------------------------------

local function resolveBurnoutNavPos(burnoutEvent)
  if burnoutEvent.triggerName then
    local startObj = scenetree.findObject(burnoutEvent.triggerName)
    if startObj then return startObj:getPosition() end
  end
  if type(burnoutEvent.zoneName) == 'string' and burnoutEvent.zoneName ~= '' then
    local data = burnoutConfig.loadLevelData(getCurrentLevel())
    return getZoneCentroid(data.zonesByName[burnoutEvent.zoneName])
  end
  return nil
end

local function navigateToEvent(raceName)
  local burnoutEvent = getBurnoutDefinitionByEventId(raceName)
  local race = not burnoutEvent and loadRaceData()[raceName]
  local pos = nil
  if burnoutEvent then
    pos = resolveBurnoutNavPos(burnoutEvent)
  elseif race and hasType(race.type, 'pulling') then
    local pullPosition = pullStagingPosition(getCurrentLevel(), raceName)
    if pullPosition then pos = vec3(pullPosition.x, pullPosition.y, pullPosition.z) end
  else
    local startObj = eventSceneObject(raceName, race)
    if startObj then
      pos = startObj:getPosition()
    elseif navTargets[raceName] then
      pos = navTargets[raceName]
    end
  end
  if pos and core_groundMarkers then
    core_groundMarkers.setPath(pos, { clearPathOnReachingTarget = true })
  end
end

M.getEventsData = getEventsData
M.buildEventsData = buildEventsData
M.navigateToEvent = navigateToEvent

return M
