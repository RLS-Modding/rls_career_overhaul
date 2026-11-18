-- Owns class and driver lookup with event snapshot support.
-- Reads settings/motorsportEvents/dragDrivers.json and classes.json; drag/configInfo.lua adds approved builds.
local M = {}
local FILE = '/settings/motorsportEvents/dragDrivers.json'
local data, classesById, driversById, driversByClass

local function copy(value)
  if type(value) ~= 'table' then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

local function load()
  if data then return end
  data = jsonReadFile(FILE)
  if type(data) ~= 'table' or (data.version ~= 1 and data.version ~= 2) then data = {} end
  if data.version == 2 then
    local authored = assert(jsonReadFile('/settings/motorsportEvents/classes.json'), 'Missing motorsport classes.json')
    assert(authored.version == 1 and type(authored.classes) == 'table', 'Invalid motorsport classes.json')
    data.classes = authored.classes
  end
  classesById, driversById, driversByClass = {}, {}, {}
  local authoredConfigs = require('overhaul/events/motorsportEvents/drag/configInfo').read(data.classes)
  data.drivers = data.drivers or {}
  for _, driver in ipairs(authoredConfigs) do data.drivers[#data.drivers + 1] = driver end
  for _, class in ipairs(data.classes or {}) do
    assert(type(class.id) == 'string' and not classesById[class.id], 'Duplicate/missing motorsport class ID')
    classesById[class.id] = class
    driversByClass[class.id] = {}
  end
  for _, driver in ipairs(data.drivers or {}) do
    assert(type(driver.id) == 'string' and not driversById[driver.id], 'Duplicate/missing motorsport config entry ID')
    driversById[driver.id] = driver
    local seen = {}
    for _, id in ipairs(driver.classIds or {driver.classId}) do
      local list = driversByClass[id]
      assert(list or data.version == 1, 'Unknown motorsport class: ' .. tostring(id))
      if list and not seen[id] then list[#list + 1], seen[id] = driver, true end
    end
  end
  -- New fields reuse approved official builds. Keep original approvals and timing
  -- provenance intact; snapshots capture the resulting memberships for this event.
  for _, class in ipairs(data.classes or {}) do
    local seen = {}
    for _, id in ipairs(class.opponentConfigIds or {}) do
      local driver = assert(driversById[id], 'Unknown official opponent: ' .. tostring(id))
      assert(not seen[id], 'Duplicate class opponent: ' .. id)
      seen[id] = true
      local present = false
      for _, existing in ipairs(driver.classIds or {driver.classId}) do if existing == class.id then present = true end end
      if not present then
        driver.classIds = driver.classIds or {driver.classId}
        driver.classIds[#driver.classIds + 1] = class.id
        driversByClass[class.id][#driversByClass[class.id] + 1] = driver
      end
    end
  end
end

function M.listClasses(leagueId, eventState)
  if not (eventState and eventState.classDefinitions) then load() end
  local result = {}
  for _, class in ipairs(eventState and eventState.classDefinitions or data.classes or {}) do
    if not leagueId or class.leagueId == leagueId then result[#result + 1] = copy(class) end
  end
  return result
end

function M.getClass(classId, eventState)
  if eventState and eventState.classDefinitions then
    for _, class in ipairs(eventState.classDefinitions) do if class.id == classId then return copy(class) end end
    return nil
  end
  load()
  return copy(classesById[classId])
end

function M.drivers(classId, eventState)
  if eventState and eventState.configDefinitions then
    local result = {}
    for _, driver in ipairs(eventState.configDefinitions) do
      local matches = classId == nil
      for _, id in ipairs(driver.classIds or {driver.classId}) do if id == classId then matches = true end end
      if matches then result[#result + 1] = copy(driver) end
    end
    return result
  end
  load()
  if classId then return copy(driversByClass[classId] or {}) end
  return copy(data.drivers or {})
end

function M.getDriver(id)
  load()
  return copy(driversById[id])
end

-- Expanded fields select distinct official builds; older fields retain their
-- original person-based deduplication (including already-running snapshots).
function M.opponentIdentity(driver, class)
  if class and class.opponentConfigIds then return driver.id end
  return driver.driverId or driver.id
end

function M.refreshNames(event)
  if not event or event.phase == 'complete' then return end
  load()
  local function refresh(entrants)
    for _, entrant in ipairs(entrants or {}) do
      local driver = driversById[entrant.id]
      if driver and not entrant.player then
        entrant.name, entrant.driverName = driver.driverName, driver.driverName
      end
    end
  end
  refresh(event.entrants)
  for _, session in ipairs(event.classes or {}) do refresh(session.entrants) end
  for _, row in ipairs(event.registrations or {}) do refresh(row.qualifyingOpponents) end
end

return M
