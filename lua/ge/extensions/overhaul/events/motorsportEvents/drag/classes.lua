-- Owns live vehicle inspection and class result grading.
-- drag/equipment.lua supplies equipment traits; definitions.lua supplies rules; vehicleSettings.lua supplies model overrides.
local M = {}
local catalog = require('overhaul/events/motorsportEvents/drag/catalog')
local finishOrder = require('overhaul/events/motorsportEvents/drag/finishOrder')
local interference = require('overhaul/events/motorsportEvents/drag/interference')
local definitions = require('overhaul/events/motorsportEvents/definitions')
local equipment = require('overhaul/events/motorsportEvents/drag/equipment')
local vehicleSettings = require('overhaul/events/motorsportEvents/vehicleSettings')

local function call(module, name, ...)
  if not module or type(module[name]) ~= 'function' then return nil end
  local ok, result = pcall(module[name], ...)
  return ok and result or nil
end

local function text(value)
  return type(value) == 'string' and value:lower() or ''
end

local function installed(config, vdata)
  local result = {}
  local definitions = vdata and vdata.activePartsData or {}
  local function add(slot, name)
    if type(name) == 'string' and name ~= '' and name ~= 'none' then
      result[#result + 1] = {slot = text(slot), name = text(name), data = definitions[name] or {}}
    end
  end
  if vdata and type(vdata.activeParts) == 'table' and next(vdata.activeParts) then
    for slot, name in pairs(vdata.activeParts) do add(slot, name) end
  elseif type(config.partsTree) == 'table' then
    local function visit(node)
      add(node.id, node.chosenPartName)
      for _, child in pairs(node.children or {}) do visit(child) end
    end
    visit(config.partsTree)
  elseif type(config.parts) == 'table' then
    for slot, name in pairs(config.parts) do add(slot, name) end
  end
  return result, #result > 0
end

local function devices(vdata)
  local result = {}
  for _, row in pairs(vdata and vdata.powertrain or {}) do
    if type(row) == 'table' and (row.type or row[1]) ~= 'type' then
      local options = type(row[5]) == 'table' and row[5] or {}
      result[#result + 1] = {type = row.type or row[1], name = row.name or row[2],
        inputName = row.inputName or row[3], connectedWheel = row.connectedWheel or options.connectedWheel}
    end
  end
  return result
end

local function powertrainTraits(vdata)
  local rows, byName = devices(vdata), {}
  for _, row in ipairs(rows) do if row.name then byName[row.name] = row end end
  local function powered(row, visited)
    local kind = text(row.type)
    if kind == 'combustionengine' or kind == 'electricmotor' then return true end
    local parent = byName[row.inputName]
    if not parent or visited[parent] then return false end
    visited[parent] = true
    return powered(parent, visited)
  end
  local front, rear, unknownWheel, manual = false, false, false, nil
  for _, row in ipairs(rows) do
    local kind = text(row.type)
    if kind == 'manualgearbox' then manual = true
    elseif kind:find('gearbox', 1, true) and manual == nil then manual = false end
    if row.connectedWheel and powered(row, {}) then
      local wheel = text(row.connectedWheel)
      if wheel:match('^f') then front = true
      elseif wheel:match('^r') then rear = true
      else unknownWheel = true end
    end
  end
  local drivetrain
  if not unknownWheel and (front or rear) then
    drivetrain = front and rear and 'AWD' or front and 'FWD' or 'RWD'
  end
  return drivetrain, manual
end

local function connectedInduction(vdata, kind)
  local known = false
  for _, device in ipairs(devices(vdata)) do
    if text(device.type) == 'combustionengine' then
      local engine = vdata[device.name]
      if type(engine) == 'table' then
        known = true
        local name = engine[kind]
        if type(name) == 'string' and type(vdata[name]) == 'table' and next(vdata[name]) then return true end
      end
    end
  end
  if known then return false end
end

local function partTraits(parts, complete)
  local result = {}
  if complete then result.rollCage, result.nitrous, result.turbocharger, result.supercharger = false, false, false, false end
  local front, rear, tireCount, unknownTire, badTire = false, false, 0, false, false
  for _, part in ipairs(parts) do
    local name = part.name .. ' ' .. text(part.data.information and part.data.information.name)
    if name:gsub('[%s_%-]', ''):find('rollcage', 1, true) then result.rollCage = true end
    if name:find('nitrous', 1, true) or name:find('n2o', 1, true) then result.nitrous = true end
    if part.data.turbocharger or name:find('turbo', 1, true) then result.turbocharger = true end
    if part.data.supercharger or name:find('supercharger', 1, true) then result.supercharger = true end
    if part.name:find('differential', 1, true) then
      if part.slot:find('differential_f', 1, true) or part.slot:find('differential_front', 1, true) then front = true end
      if part.slot:find('differential_r', 1, true) or part.slot:find('differential_rear', 1, true) then rear = true end
    end
    if part.slot:find('transmission', 1, true) or part.slot:find('gearbox', 1, true) then
      if name:find('automatic', 1, true) or name:find('sequential', 1, true) or name:find('dct', 1, true) or name:find('cvt', 1, true)
        or part.name:match('_%d+a[%W_]') or part.name:match('_%d+a$') then result.manual = false
      elseif name:find('manual', 1, true) or part.name:match('_%d+m[%W_]') or part.name:match('_%d+m$') then result.manual = true end
    end
    if (part.slot:find('engine', 1, true) or part.slot:find('fueltank', 1, true)) and name:find('diesel', 1, true) then result.diesel = true end
    if (part.slot:find('tire', 1, true) or part.name:match('^tire_')) and not part.slot:find('spare', 1, true) then
      tireCount = tireCount + 1
      if name:find('race', 1, true) or name:find('racing', 1, true) or name:find('drag', 1, true) or name:find('slick', 1, true) then badTire = true
      elseif name:find('sport', 1, true) then
      elseif name:find('standard', 1, true) or name:find('allseason', 1, true) or name:find('all season', 1, true)
        or name:find('offroad', 1, true) or name:find('rally', 1, true) or name:find('mud', 1, true) then badTire = true
      else unknownTire = true end
    end
  end
  if front or rear then result.drivetrain = front and rear and 'AWD' or front and 'FWD' or 'RWD' end
  if badTire then result.sportTires = false
  elseif tireCount > 0 and not unknownTire then result.sportTires = true end
  return result
end

local function fuelType(vdata)
  local diesel, other = false, false
  for _, row in pairs(vdata and vdata.energyStorage or {}) do
    if type(row) == 'table' then
      local name = row.name or row[2]
      local storage = name and vdata[name]
      local kind = text(row.energyType or type(storage) == 'table' and storage.energyType)
      if kind == 'diesel' then diesel = true end
      if kind == 'gasoline' or kind == 'electricenergy' then other = true end
    end
  end
  if diesel then return true end
  if other then return false end
end

function M.leagues(eventState) return definitions.leagues(eventState) end

function M.inspect(inventoryId, vehicleId)
  local inventory = overhaul_career_garage_inventory
  inventoryId = inventoryId or call(inventory, 'getInventoryIdFromVehicleId', vehicleId)
  vehicleId = vehicleId or call(inventory, 'getVehicleIdFromInventoryId', inventoryId)
  local mappedId = vehicleId and call(inventory, 'getInventoryIdFromVehicleId', vehicleId)
  if inventoryId and mappedId and tostring(inventoryId) ~= tostring(mappedId) then
    return nil, 'This vehicle no longer matches the selected inventory entry.'
  end
  local saved = call(inventory, 'getVehicle', inventoryId)
  if not saved and inventoryId then
    local list = call(inventory, 'getVehicles') or {}
    saved = list[inventoryId] or list[tonumber(inventoryId)]
  end
  local vehicle = vehicleId and be and be:getObjectByID(vehicleId)
  local live = vehicle and call(core_vehicle_manager, 'getVehicleData', vehicleId)
  local config = live and live.config or saved and saved.config
  if type(config) ~= 'table' and vehicle and type(deserialize) == 'function' then
    local ok, value = pcall(deserialize, vehicle.partConfig)
    if ok and type(value) == 'table' then config = value end
  end
  if type(config) ~= 'table' and vehicle and type(vehicle.partConfig) == 'string' and type(jsonReadFile) == 'function' then
    config = jsonReadFile(vehicle.partConfig)
  end
  local model = vehicle and vehicle.JBeam or saved and saved.model or config and config.model
  if not model or type(config) ~= 'table' then return nil, 'This vehicle configuration is not available.' end
  local snapshot = type(serialize) == 'function' and serialize(config) or nil
  if not snapshot then return nil, 'This vehicle configuration could not be saved for entry.' end
  local details = vehicle and call(core_vehicles, 'getVehicleDetails', vehicleId)
  local filename = config.partConfigFilename
  local configKey = type(filename) == 'string' and filename:match('([^/]+)%.pc$')
  local info = details and details.configs or configKey and call(core_vehicles, 'getConfig', model, configKey) or {}
  local modelInfo = details and details.model
  if not modelInfo then local data = call(core_vehicles, 'getModel', model); modelInfo = data and data.model or {} end
  local vdata = live and live.vdata
  local parts, complete = installed(config, vdata)
  local traits = partTraits(parts, complete)
  traits.model = model
  traits.configId = configKey and (model .. '/' .. configKey) or nil
  if vdata then
    if type(vdata.turbocharger) == 'table' and next(vdata.turbocharger) then traits.turbocharger = true end
    if type(vdata.supercharger) == 'table' and next(vdata.supercharger) then traits.supercharger = true end
    for _, kind in ipairs({'turbocharger', 'supercharger'}) do
      local connected = connectedInduction(vdata, kind)
      if connected ~= nil then traits[kind] = connected end
    end
  end
  for key, value in pairs(equipment.inspect(parts, vdata)) do traits[key] = value end
  local drivetrain, manual = powertrainTraits(vdata)
  traits.drivetrain = drivetrain or traits.drivetrain
  if manual ~= nil then traits.manual = manual end
  local diesel = fuelType(vdata)
  if diesel ~= nil then traits.diesel = diesel end
  traits.year = tonumber(saved and saved.year) or tonumber(info.Year)
  local years = info.Years or modelInfo.Years
  if not traits.year and type(years) == 'table' then traits.year = tonumber(years.max) or tonumber(years.min) end
  local vehicleType = text(info.Type or modelInfo.Type)
  if vehicleSettings.isUtilityModel(model) then traits.truck = true
  elseif vehicleType ~= '' then traits.truck = vehicleType:find('truck', 1, true) ~= nil or vehicleType == 'pickup' or vehicleType == 'van' or vehicleType == 'suv' end
  return {inventoryId = inventoryId, vehicleId = vehicleId, model = model, config = snapshot, traits = traits}
end

local function eligible(class, traits, eventState, elapsed)
  local rules = class.rules or definitions.data(eventState).categories[class.category]
  if not rules then return nil, 'Unknown class category: ' .. tostring(class.category) end
  return definitions.evaluate(rules, traits, elapsed)
end

local function finite(value)
  local number = tonumber(value)
  if number and number == number and number ~= math.huge and number ~= -math.huge then return number end
end

local function tech(leagueId, traits, elapsed, eventState)
  local league = definitions.league(leagueId, eventState)
  if not league then return nil, 'The selected league is unavailable.', 'class' end
  local valid, err, code = definitions.evaluate(league.rules, traits, elapsed)
  if not valid then return nil, err, code end
  return definitions.evaluateEquipment(league.equipment, traits)
end

local function breakout(time, index)
  return string.format('Breakout: %.3f s, under the %.3f s index', time, index)
end

function M.canEnter(leagueId, classId, traits, eventState)
  local class = catalog.getClass(classId, eventState)
  if not class or class.leagueId ~= leagueId or not definitions.accepts(class, eventState) then return nil, 'Choose a class in the selected league.', 'class' end
  traits = traits or {}
  local valid, err, code = tech(leagueId, traits, nil, eventState)
  if not valid then return nil, err, code end
  local permitted, missing, reason = eligible(class, traits, eventState)
  if missing then return nil, missing, reason or 'category' end
  if not permitted then return nil, 'This vehicle does not meet the ' .. class.name .. ' category requirements.', 'category' end
  valid, err, code = definitions.evaluateEquipment(class.equipment, traits)
  if not valid then return nil, err, code end
  return class
end

-- Every requirement the car misses for a class, not only the first, so registration can show what to change.
-- Returns nil when the car can enter.
function M.blockers(leagueId, classId, traits, eventState)
  local ok, first = M.canEnter(leagueId, classId, traits, eventState)
  if ok then return nil end
  traits = traits or {}
  local class, league = catalog.getClass(classId, eventState), definitions.league(leagueId, eventState)
  local list, seen = {}, {}
  local function add(valid, message) if not valid and message and not seen[message] then seen[message] = true; list[#list + 1] = message end end
  local function each(rules) for _, rule in ipairs(rules or {}) do add(definitions.evaluate({rule}, traits)) end end
  if league then each(league.rules); add(definitions.evaluateEquipment(league.equipment, traits)) end
  if class then
    each(class.rules or definitions.data(eventState).categories[class.category])
    add(definitions.evaluateEquipment(class.equipment, traits))
  end
  if #list == 0 then list[1] = first end
  return list
end

function M.validate(classId, elapsedTime, traits, eventState)
  local class = catalog.getClass(classId, eventState)
  if not class then return nil, 'The selected drag class is unavailable.', 'class' end
  local time = finite(elapsedTime)
  if not time or time <= 0 then return nil, 'Complete a valid qualifying pass first.', 'invalid_time' end
  local valid, err, code = M.canEnter(class.leagueId, classId, traits, eventState)
  if not valid then return nil, err, code end
  if class.indexSeconds and time < class.indexSeconds then return nil, breakout(time, class.indexSeconds), 'breakout' end
  valid, err, code = tech(class.leagueId, traits or {}, time, eventState)
  if not valid then return nil, err, code end
  valid, err, code = eligible(class, traits or {}, eventState, time)
  if not valid then return nil, err, code end
  return class
end

local function copy(value)
  if type(value) ~= 'table' then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

local function winnerAmong(rows, nativeWinner)
  return finishOrder.winner(rows, nativeWinner)
end

function M.applyResult(classId, result, phase, eventState)
  local class = catalog.getClass(classId, eventState)
  if not class then return nil, 'The selected drag class is unavailable.', 'class' end
  if type(result) ~= 'table' then return nil, 'The race result is unavailable.', 'invalid_result' end
  local adjusted = copy(result)
  if type(adjusted.rows) ~= 'table' then return adjusted end
  if phase == 'eliminations' and adjusted.walkover and adjusted.interference then
    if not interference.validate(adjusted, eventState) then return nil, 'The lane interference result is unavailable.', 'invalid_result' end
    return adjusted
  end
  if phase == 'eliminations' and adjusted.walkover then
    local winner, loser
    for _, row in ipairs(adjusted.rows) do
      if row.time ~= nil or row.reaction ~= nil then return nil, 'A staging walkover cannot contain measured times.', 'invalid_result' end
      if row.entrantId == adjusted.winnerId and row.walkover and row.valid == true then winner = row
      elseif row.valid == false and row.reason == 'Did not stage' then loser = row end
    end
    local player, opponent
    for _, entrant in ipairs(eventState and eventState.entrants or {}) do
      if winner and entrant.id == winner.entrantId and entrant.player then player = true end
      if loser and entrant.id == loser.entrantId and not entrant.player then opponent = true end
    end
    if #adjusted.rows ~= 2 or not player or not opponent then return nil, 'The staging walkover is unavailable.', 'invalid_result' end
    return adjusted
  end
  local legal, breakouts = {}, {}
  for _, row in ipairs(adjusted.rows) do
    local time = finite(row.time)
    if row.nativeValid == nil then row.nativeValid, row.nativeReason = row.valid == true, row.reason end
    if phase == 'eliminations' and not row.nativeValid then row.valid, row.reason = false, row.nativeReason or row.reason end
    local qualifyingValid = phase ~= 'eliminations' and row.valid == true
    if class.indexSeconds and time and time > 0 and time < class.indexSeconds then
      row.breakout, row.breakoutAmount = true, class.indexSeconds - time
      if row.nativeValid or qualifyingValid then row.valid, row.reason = false, breakout(time, class.indexSeconds) end
    end
    if (phase == 'eliminations' and row.nativeValid or phase ~= 'eliminations' and row.valid == true) and time and time > 0 then
      if row.valid == true then legal[#legal + 1] = row
      elseif row.breakout and row.breakoutAmount and row.breakoutAmount > 0 then breakouts[#breakouts + 1] = row end
    end
  end
  if phase == 'eliminations' then
    if #legal > 0 then adjusted.winnerId = winnerAmong(legal, adjusted.winnerId)
    elseif #breakouts > 0 then
      local closest, amount = {}, math.huge
      for _, row in ipairs(breakouts) do
        if row.breakoutAmount < amount then closest, amount = {row}, row.breakoutAmount
        elseif row.breakoutAmount == amount then closest[#closest + 1] = row end
      end
      adjusted.winnerId = winnerAmong(closest, adjusted.winnerId)
    else adjusted.winnerId = nil end
  elseif #legal == 0 then adjusted.winnerId = nil
  elseif adjusted.winnerId then
    local winnerValid = false
    for _, row in ipairs(legal) do if row.entrantId == adjusted.winnerId then winnerValid = true end end
    if not winnerValid then adjusted.winnerId = winnerAmong(legal) end
  end
  return adjusted
end

function M.assign(leagueId, elapsedTime, traits, eventState)
  local league
  for _, item in ipairs(M.leagues(eventState)) do if item.id == leagueId then league = item end end
  if not league then return nil, 'Choose a drag league first.' end
  local time = finite(elapsedTime)
  if not time or time <= 0 then return nil, 'Complete a valid qualifying pass first.' end
  traits = traits or {}
  local valid, err, code = tech(leagueId, traits, time, eventState)
  if not valid then return nil, err, code end
  local candidates, unknown = {}, {}
  for _, class in ipairs(catalog.listClasses(leagueId, eventState)) do
    if not class.indexSeconds or time >= class.indexSeconds then
      local valid, missing = eligible(class, traits, eventState, time)
      if valid then
        class.distance = math.abs(time - (class.medianET or class.indexSeconds or time))
        class.specificity = class.category == 'open' and 0 or (class.category == 'fwd' or class.category == 'rwd' or class.category == 'awd') and 1 or 2
        candidates[#candidates + 1] = class
      elseif missing then unknown[missing] = true end
    end
  end
  table.sort(candidates, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    if a.specificity ~= b.specificity then return a.specificity > b.specificity end
    return a.id < b.id
  end)
  if candidates[1] then candidates[1].distance, candidates[1].specificity = nil, nil; return candidates[1] end
  local missing = {}
  for key in pairs(unknown) do missing[#missing + 1] = key end
  table.sort(missing)
  if #missing > 0 then return nil, 'Class eligibility could not be determined: ' .. table.concat(missing, ', ') .. '.' end
  return nil, string.format('No %s class accepts this vehicle and its %.3f second qualifying time.', league.name, time)
end

return M
