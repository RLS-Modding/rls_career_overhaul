-- Owns competition validation and per-event definition snapshots.
-- Reads settings/motorsportEvents/competition.json; drag/catalog.lua supplies classes and drivers for accepted events.
-- Authored competition data. Each new event owns a snapshot, never a live reference.
local M = {}
local FILE = '/settings/motorsportEvents/competition.json'
local cached

local function copy(value)
  if type(value) ~= 'table' then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

local function check(ok, message)
  assert(ok, 'Invalid motorsport definition: ' .. message)
end

local function integer(value, minimum, maximum)
  return type(value) == 'number' and value == math.floor(value) and value >= minimum and value <= maximum
end

local function identifiers(rows, label)
  check(type(rows) == 'table' and #rows > 0, label .. ' must be a nonempty array')
  local seen = {}
  for _, row in ipairs(rows) do
    check(type(row) == 'table' and type(row.id) == 'string' and row.id ~= '' and not seen[row.id], label .. ': missing/duplicate id')
    seen[row.id] = row
  end
  return seen
end

local traits = {model = true, drivetrain = true, year = true, manual = true, truck = true, diesel = true,
  nitrous = true, turbocharger = true, supercharger = true, rollCage = true, sportTires = true, tireType = true, tireFrictionCoefMax = true}
local tireTypes = {sport = true, standard = true, allSeason = true, drag = true, slick = true,
  semiSlick = true, race = true, offroad = true, rally = true, mud = true, winter = true}
function M.validateEquipment(equipment)
  if equipment == nil then return end
  check(type(equipment) == 'table', 'equipment must be an object')
  check(equipment.rollCageRequired == nil or type(equipment.rollCageRequired) == 'boolean', 'rollCageRequired must be boolean')
  if equipment.allowedTireTypes ~= nil then
    check(type(equipment.allowedTireTypes) == 'table' and #equipment.allowedTireTypes > 0, 'allowedTireTypes must be nonempty')
    for _, kind in ipairs(equipment.allowedTireTypes) do check(tireTypes[kind], 'unknown tire type ' .. tostring(kind)) end
  end
  local limit = equipment.maxTireFrictionCoef
  check(limit == nil or type(limit) == 'number' and limit >= 0 and limit < math.huge, 'invalid maxTireFrictionCoef')
end

function M.evaluateEquipment(equipment, observed)
  if not equipment then return true end
  if equipment.rollCageRequired then
    if observed.rollCage == nil then return nil, 'Roll cage status could not be determined.', 'unknown_trait' end
    if not observed.rollCage then return nil, 'This class or league requires a roll cage.', 'tech' end
  end
  if equipment.allowedTireTypes then
    if not observed.tireTypes or #observed.tireTypes == 0 then return nil, 'Tire type could not be determined on every fitted tire.', 'unknown_trait' end
    local allowed = {}; for _, kind in ipairs(equipment.allowedTireTypes) do allowed[kind] = true end
    for _, kind in ipairs(observed.tireTypes) do
      if not allowed[kind] then return nil, 'Every fitted tire must be one of: ' .. table.concat(equipment.allowedTireTypes, ', ') .. '.', 'tech' end
    end
  end
  if equipment.maxTireFrictionCoef ~= nil then
    if observed.tireFrictionCoefMax == nil then return nil, 'Compiled tire friction is unavailable.', 'unknown_trait' end
    if observed.tireFrictionCoefMax > equipment.maxTireFrictionCoef then return nil, 'Tire friction exceeds the permitted coefficient.', 'tech' end
  end
  return true
end
function M.validateRules(rules)
  check(type(rules) == 'table', 'rules must be an array')
  for _, rule in ipairs(rules) do
    check(type(rule) == 'table' and traits[rule.trait], 'unknown eligibility trait')
    check(rule.equals ~= nil or rule.lessThan ~= nil or rule.oneOf ~= nil, 'rule needs equals, lessThan or oneOf')
    if rule.oneOf ~= nil then
      check(type(rule.oneOf) == 'table' and #rule.oneOf > 0, 'oneOf must be a nonempty array')
      for _, value in ipairs(rule.oneOf) do check(type(value) == 'string' and value ~= '', 'invalid oneOf value') end
    end
    if rule.exceptModels ~= nil then
      check(type(rule.exceptModels) == 'table', 'exceptModels must be an array')
      for _, model in ipairs(rule.exceptModels) do check(type(model) == 'string' and model ~= '', 'invalid exempt model') end
    end
    if rule.exceptConfigs ~= nil then
      check(type(rule.exceptConfigs) == 'table', 'exceptConfigs must be an array')
      for _, config in ipairs(rule.exceptConfigs) do check(type(config) == 'string' and config:match('^[%w_%-]+/[%w_%-]+$'), 'invalid exempt config') end
    end
    if rule.lessThan ~= nil then check(type(rule.lessThan) == 'number' and rule.lessThan < math.huge, 'invalid rule threshold') end
    if rule.whenElapsedBelow ~= nil then check(type(rule.whenElapsedBelow) == 'number' and rule.whenElapsedBelow > 0 and rule.whenElapsedBelow < math.huge, 'invalid elapsed threshold') end
  end
end

function M.validate(data)
  check(type(data) == 'table' and data.version == 1, 'unsupported competition version')
  local leagues = identifiers(data.leagues, 'leagues')
  for _, league in ipairs(data.leagues) do
    check(type(league.name) == 'string' and integer(league.fee, 0, 100000000), 'league name/fee')
    M.validateRules(league.rules)
    M.validateEquipment(league.equipment)
  end
  check(type(data.categories) == 'table', 'categories missing')
  for _, rules in pairs(data.categories) do M.validateRules(rules) end
  local events = identifiers(data.events, 'events')
  check(events[data.defaultEventId] ~= nil, 'default event does not exist')
  if data.rotation then
    local rotation = data.rotation
    check(type(rotation.enabled) == 'boolean' and events[rotation.eventId], 'invalid rotation event')
    check(integer(rotation.offerMinuteOfDay, 0, 1439), 'invalid offer minute')
    check(type(rotation.leagueIds) == 'table' and #rotation.leagueIds > 0, 'rotation leagues missing')
    local seen = {}
    for _, id in ipairs(rotation.leagueIds) do
      check(leagues[id] and not seen[id], 'unknown/duplicate rotation league')
      seen[id] = true
    end
  end
  for _, event in ipairs(data.events) do
    check(type(event.name) == 'string', 'event name missing')
    check(integer(event.opponentCount, 1, 128), 'opponentCount must be 1..128')
    check(integer(event.qualifyingAttempts, 1, 20), 'qualifyingAttempts must be 1..20')
    check(event.qualifyingFieldSize == nil or integer(event.qualifyingFieldSize, 2, 128), 'qualifyingFieldSize must be 2..128')
    check(integer(event.earlyHeatBudget, 0, 10000), 'earlyHeatBudget invalid')
    check(event.finalsFieldSize == 2 or event.finalsFieldSize == 4 or event.finalsFieldSize == 8 or event.finalsFieldSize == 16 or event.finalsFieldSize == 32, 'finalsFieldSize must be a supported power of two')
    check(integer(event.passIntervalSeconds, 0, 600) and integer(event.maxPassIntervalSeconds, event.passIntervalSeconds, 600), 'pass intervals invalid')
    check(type(event.qualifyingCompression) == 'boolean', 'qualifyingCompression must be boolean')
    local previous = 1
    for _, stage in ipairs({'registration', 'qualifying', 'eliminations', 'finals'}) do
      local row = event.stages and event.stages[stage]
      check(type(row) == 'table' and integer(row.day, previous, 365) and type(row.label) == 'string', 'invalid/unsorted stage ' .. stage)
      check(row.minuteOfDay == nil or integer(row.minuteOfDay, 0, 1439), 'invalid stage opening minute')
      previous = row.day
    end
    check(event.stages.registration.day == 1, 'registration must start on day 1')
    if event.schedule then
      check(event.schedule.version == 1, 'unsupported schedule')
      for _, key in ipairs({'qualifyingGroupMinutes', 'eliminationRoundMinutes', 'turnaroundMinutes'}) do
        check(integer(event.schedule[key], 0, 1440), 'invalid schedule spacing ' .. key)
      end
      check(event.schedule.venueActivityRadius == nil or integer(event.schedule.venueActivityRadius, 100, 10000), 'invalid venue activity radius')
      local last = -1
      for _, stage in ipairs({'registration', 'qualifying', 'eliminations', 'finals'}) do
        local row = event.stages[stage]
        check(integer(row.minuteOfDay, 0, 1439), 'scheduled stage needs opening minute')
        local opening = row.day * 1440 + row.minuteOfDay
        check(opening >= last, 'stage opening times must be ordered')
        last = opening
      end
    end
    for _, id in ipairs(event.leagueIds or {}) do check(leagues[id] ~= nil, 'unknown event league ' .. tostring(id)) end
    check(type(event.prizes) == 'table', 'prizes missing')
    if event.prizes.referenceLeagueId ~= nil then
      local reference = leagues[event.prizes.referenceLeagueId]
      check(reference ~= nil and reference.fee > 0, 'prize reference league needs a positive registration fee')
    end
    for _, key in ipairs({'winner', 'runnerUp', 'third', 'topTen', 'participation'}) do
      check(integer(event.prizes[key], 0, 100000000), 'invalid prize ' .. key)
    end
  end
  return data
end

local function load()
  if not cached then cached = M.validate(jsonReadFile(FILE)) end
  return cached
end

function M.data(eventState) return eventState and eventState.competition or load() end
function M.event(eventState)
  if eventState and eventState.eventDefinition then return eventState.eventDefinition end
  local data = M.data(eventState)
  for _, row in ipairs(data.events) do if row.id == data.defaultEventId then return row end end
end
function M.totalDays(eventState) return M.event(eventState).stages.finals.day end
function M.qualifyingFieldSize(eventState)
  local definition = M.event(eventState)
  -- Older event snapshots predate the explicit qualifying cutoff.
  return definition.qualifyingFieldSize or 16
end
function M.validateCatalog(classes, drivers, data)
  data = data or load()
  local byClass = identifiers(classes, 'classes')
  local leagues = identifiers(data.leagues, 'leagues')
  for _, class in ipairs(classes) do
    check(leagues[class.leagueId] ~= nil, 'unknown class league ' .. tostring(class.leagueId))
    check(type(class.name) == 'string', 'class name missing')
    M.validateRules(class.rules or data.categories[class.category])
    M.validateEquipment(class.equipment)
    check(class.indexSeconds == nil or type(class.indexSeconds) == 'number' and class.indexSeconds > 0 and class.indexSeconds < math.huge, 'invalid class index')
  end
  for _, event in ipairs(data.events) do
    for _, id in ipairs(event.classIds or {}) do check(byClass[id] ~= nil, 'unknown event class ' .. tostring(id)) end
  end
  for _, driver in ipairs(drivers) do
    check(type(driver.model) == 'string' and type(driver.config) == 'string', 'opponent model/config missing')
    for _, id in ipairs(driver.classIds or {driver.classId}) do check(byClass[id] ~= nil, 'unknown config class ' .. tostring(id)) end
  end
  return true
end
function M.leagues(eventState) return copy(M.data(eventState).leagues) end
function M.league(id, eventState)
  for _, row in ipairs(M.data(eventState).leagues) do if row.id == id then return row end end
end
local function contains(list, id)
  if list == nil then return true end
  for _, value in ipairs(list) do if value == id then return true end end
  return false
end
function M.accepts(class, eventState)
  local definition = M.event(eventState)
  return class ~= nil and contains(definition.leagueIds, class.leagueId) and contains(definition.classIds, class.id)
end
function M.available(level)
  local result = {}
  for _, event in ipairs(load().events) do
    if contains(event.mapIds, level) then result[#result + 1] = copy(event) end
  end
  return result
end
function M.snapshot(id, level)
  local data = load()
  for _, event in ipairs(data.events) do
    if event.id == (id or data.defaultEventId) then
      if not contains(event.mapIds, level) then return nil, 'This event is not available on this map.' end
      return {competition = copy(data), eventDefinition = copy(event), definitionId = event.id}
    end
  end
  return nil, 'The event definition is unavailable.'
end

-- Rules are conjunctions. Missing observations fail closed, never grant eligibility.
function M.evaluate(rules, observed, elapsed)
  for _, rule in ipairs(rules or {}) do
    local exempt = false
    for _, model in ipairs(rule.exceptModels or {}) do if observed.model == model then exempt = true end end
    for _, config in ipairs(rule.exceptConfigs or {}) do if observed.configId == config then exempt = true end end
    if not exempt and (not rule.whenElapsedBelow or elapsed and elapsed < rule.whenElapsedBelow) then
      local value = observed[rule.trait]
      if value == nil then return nil, 'Could not determine ' .. rule.trait .. '.', 'unknown_trait' end
      local included = rule.oneOf == nil
      for _, allowed in ipairs(rule.oneOf or {}) do if value == allowed then included = true end end
      if not included or rule.equals ~= nil and value ~= rule.equals or rule.lessThan ~= nil and (type(value) ~= 'number' or value >= rule.lessThan) then
        return nil, rule.message or ('Requirement not met: ' .. rule.trait), 'tech'
      end
    end
  end
  return true
end

-- Events created before authored snapshots retain their original championship rules.
function M.restoreLegacySnapshot(eventState)
  if not eventState or eventState.competition and eventState.classDefinitions and eventState.configDefinitions then return end
  local base = '/settings/motorsportEvents/legacy/'
  local data, classes, drivers = jsonReadFile(base .. 'competition.json'), jsonReadFile(base .. 'classes.json'), jsonReadFile(base .. 'dragDrivers.json')
  if not data or not classes or not drivers then return end
  eventState.competition = eventState.competition or copy(data)
  eventState.eventDefinition = eventState.eventDefinition or copy(data.events[1])
  eventState.definitionId = eventState.definitionId or data.defaultEventId
  eventState.classDefinitions = eventState.classDefinitions or copy(classes.classes)
  eventState.configDefinitions = eventState.configDefinitions or copy(drivers.drivers)
end
return M
