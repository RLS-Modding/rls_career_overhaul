local M = {}
M.dependencies = { 'career_modules_inventory', 'gameplay_events_freeroamEvents' }

local logTag = 'ui_phone_freeroamEvents'
local leaderboardManager = require('gameplay/events/freeroam/leaderboardManager')

local function getCurrentLevel()
  if getCurrentLevelIdentifier and getCurrentLevelIdentifier() then
    return getCurrentLevelIdentifier()
  end
  if core_levels and getMissionFilename and getMissionFilename() ~= '' then
    return core_levels.getLevelName(getMissionFilename())
  end
  return nil
end

local function loadRaceData()
  local level = getCurrentLevel()
  if not level or level == '' then
    log('D', logTag, "loadRaceData: no level identifier")
    return {}
  end
  local filePath = "levels/" .. level .. "/race_data.json"
  local raceData = jsonReadFile(filePath)
  local fromFile = raceData ~= nil
  raceData = raceData or { races = {} }
  local races = raceData.races or {}
  local count = 0
  for _ in pairs(races) do count = count + 1 end
  log('D', logTag, string.format("loadRaceData: path=%s, fileRead=%s, races=%d", filePath, tostring(fromFile), count))
  return races
end

local function getPlayerPos()
  local veh = getPlayerVehicle(0)
  if veh then return veh:getPosition() end
  return nil
end

local function isCareerActive()
  local state = core_gamestate and core_gamestate.state and core_gamestate.state.state
  if state == 'freeroam' then return false end
  if state == 'career' then return true end
  return career_career and career_career.isActive()
end

local function getVehicleDisplayName(vehData)
  if not vehData then return "Unknown Vehicle" end
  local name = ""
  if vehData.niceName then
    name = vehData.niceName
  elseif vehData.model then
    name = vehData.model
  end
  if vehData.configName and vehData.configName ~= "" then
    name = name .. " " .. vehData.configName
  end
  return name ~= "" and name or "Unknown Vehicle"
end

local function getEventsData()
  log('D', logTag, "getEventsData: called")
  if not isCareerActive() then
    log('D', logTag, "getEventsData: career not active, returning empty")
    guihooks.trigger('phoneFreeroamEventsData', { events = {}, careerActive = false })
    return
  end

  local levelId = getCurrentLevel()
  if not levelId or levelId == '' then
    local missionFilename = getMissionFilename and getMissionFilename() or ''
    log('D', logTag, string.format("getEventsData: no levelId (mission=%s)", tostring(missionFilename)))
    guihooks.trigger('phoneFreeroamEventsData', { events = {}, careerActive = true, levelId = '' })
    return
  end
  log('D', logTag, string.format("getEventsData: levelId=%s", levelId))

  local races = loadRaceData()
  if not races or not next(races) then
    log('D', logTag, "getEventsData: no races found")
    guihooks.trigger('phoneFreeroamEventsData', { events = {}, careerActive = true, levelId = levelId })
    return
  end

  -- Get current vehicle
  local currentVehicleId = nil
  local currentVehicleName = "No Vehicle"
  local playerVehId = be:getPlayerVehicleID(0)
  if playerVehId and playerVehId >= 0 then
    currentVehicleId = career_modules_inventory.getInventoryIdFromVehicleId(playerVehId)
  end

  -- Get all vehicles for leaderboard lookups
  local allVehicles = {}
  if career_modules_inventory and career_modules_inventory.getVehicles then
    allVehicles = career_modules_inventory.getVehicles() or {}
  end

  if currentVehicleId and allVehicles[currentVehicleId] then
    currentVehicleName = getVehicleDisplayName(allVehicles[currentVehicleId])
  end

  -- Get player position for distance calc
  local playerPos = getPlayerPos()

  local events = {}
  for raceName, race in pairs(races) do
    -- Get position from scene tree
    local pos = nil
    local distance = -1
    local startObj = scenetree.findObject("fre_start_" .. raceName)
    if startObj then
      local objPos = startObj:getPosition()
      pos = { x = objPos.x, y = objPos.y, z = objPos.z }
      if playerPos then
        distance = math.floor((objPos - playerPos):length())
      end
    end

    -- Build thumbnail path
    local thumbnail = "/levels/" .. levelId .. "/facilities/freeroamEvents/" .. raceName .. ".jpg"

    -- Get current vehicle best time
    local currentVehicleBestTime = nil
    local currentVehicleBestEntry = {}
    if currentVehicleId then
      currentVehicleBestEntry = leaderboardManager.getLeaderboardEntry(currentVehicleId, race.label) or {}
      currentVehicleBestTime = currentVehicleBestEntry.time
    end

    -- Get all vehicle records for this race
    local vehicleRecords = {}
    for invId, vehData in pairs(allVehicles) do
      local entry = leaderboardManager.getLeaderboardEntry(invId, race.label) or {}
      if entry.time or entry.driftScore or entry.topSpeed then
        table.insert(vehicleRecords, {
          inventoryId = invId,
          vehicleName = getVehicleDisplayName(vehData),
          time = entry.time,
          driftScore = entry.driftScore,
          topSpeed = entry.topSpeed,
          damagePercentage = entry.damagePercentage,
        })
      end
    end

    -- Sort records by time (fastest first)
    table.sort(vehicleRecords, function(a, b)
      if a.time and b.time then return a.time < b.time end
      if a.time then return true end
      if b.time then return false end
      return false
    end)

    events[raceName] = {
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
      driftGoal = race.driftGoal,
      hasAltRoute = (race.altRoute ~= nil),
      altRouteLabel = race.altRoute and race.altRoute.label,
      altRouteBestTime = race.altRoute and race.altRoute.bestTime,
      altRouteReward = race.altRoute and race.altRoute.reward,
      position = pos,
      distance = distance,
      thumbnail = thumbnail,
      currentVehicleBestTime = currentVehicleBestTime,
      currentVehicleName = currentVehicleName,
      vehicleRecords = vehicleRecords,
    }
  end

  local eventCount = 0
  for _ in pairs(events) do eventCount = eventCount + 1 end
  log('D', logTag, string.format("getEventsData: sending %d events", eventCount))
  guihooks.trigger('phoneFreeroamEventsData', {
    events = events,
    careerActive = true,
    currentVehicleId = currentVehicleId,
    currentVehicleName = currentVehicleName,
    levelId = levelId,
  })
end

local function navigateToEvent(raceName)
  local startObj = scenetree.findObject("fre_start_" .. raceName)
  if not startObj then return end
  local pos = startObj:getPosition()
  if pos and core_groundMarkers then
    core_groundMarkers.setPath(pos, { clearPathOnReachingTarget = true })
  end
end

M.getEventsData = getEventsData
M.navigateToEvent = navigateToEvent

return M
