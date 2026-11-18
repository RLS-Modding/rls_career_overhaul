-- Owns vehicle entry, inspection, and refund decisions.
-- drag/classes.lua inspects eligibility; weekend.lua assembles sessions; motorsportEvents.lua requests saves.
local M = {}
local classes = require('overhaul/events/motorsportEvents/drag/classes')
local catalog = require('overhaul/events/motorsportEvents/drag/catalog')
local interactions = require('overhaul/events/motorsportEvents/venueInteractions')
local roster = require('overhaul/events/motorsportEvents/drag/roster')
local bracket = require('overhaul/events/motorsportEvents/drag/bracket')
local progress = require('overhaul/events/motorsportEvents/weekendProgress')
local definitions = require('overhaul/events/motorsportEvents/definitions')
local currentEvent
-- Failed inspections per registration, kept until that car passes or the session changes.
local inspectionFailures
local inspectionInstructions = {
  registered_vehicle_missing = 'Bring your registered car to check-in, then inspect again.',
  wrong_registered_vehicle = 'Bring the car you registered for this event to check-in, then inspect again.',
  configuration_changed = "This car's installed parts changed after registration. Restore the registered parts, then inspect again. Tuning and paint changes are allowed.",
}

local function balance()
  local attributes = overhaul_career_economy_playerAttributes
  return attributes and attributes.getAttributeValue('money') or 0
end

-- The rules API supplies sentences. Adapt them once at the producer boundary,
-- so every registration view receives the same labelled requirements.
local function requirementReasons(blockers)
  if not blockers then return nil end
  local reasons = {}
  for _, message in ipairs(blockers) do
    local text = message:match('^[^;]+'):gsub('%.$', '')
    local needed = text:match('requires (.+)')
    local forbidden = text:match('does not allow (.+)')
    local unknown = text:match('^Could not determine (.+)')
    if unknown then unknown = unknown:gsub('(%l)(%u)', '%1 %2'):gsub('_', ' '):lower() end
    reasons[#reasons + 1] = {kind = needed and 'needs' or forbidden and 'notAllowed'
      or unknown and 'couldNotCheck' or 'reason', text = needed or forbidden or unknown or text}
  end
  return reasons
end

local function needsInspection(eventState, row)
  if row.excluded or row.refundPaid or eventState.phase == 'complete' then return false end
  if progress.stage(eventState) == 'registration' or progress.stage(eventState) == 'qualifying' then return true end
  if row.dnq then return false end
  for _, class in ipairs(eventState.classes or {}) do
    if class.id == (row.classId or row.declaredClassId) then
      if class.phase == 'complete' then return false end
      if not class.bracket then return true end
      local outcome = bracket.playerOutcome(class.bracket, row.id)
      return not outcome or outcome == 'Advancing' or outcome == 'Third-place race next'
    end
  end
  return true
end

local function vehicleName(row)
  local inventory = overhaul_career_garage_inventory
  return inventory and inventory.getVehicleNiceNameTranslated(row.inventoryId) or row.vehicleName or row.model
end

local function inspectionFailure(eventState, row, message, code)
  local name = vehicleName(row)
  if row.declaredClassName then name = name .. ' (' .. row.declaredClassName .. ')' end
  local failure = {ok = false, error = name .. ': ' .. message, reason = code, vehicleName = vehicleName(row),
    inventoryId = row.inventoryId, registrationId = progress.inspectionKey(row)}
  if eventState.checkIn and eventState.checkIn.inspections then
    eventState.checkIn.inspections[progress.inspectionKey(row)] = nil
  end
  local stage = progress.stage(eventState)
  if not (inspectionFailures and inspectionFailures.event == eventState and inspectionFailures.stage == stage) then
    inspectionFailures = {event = eventState, stage = stage, byRegistration = {}}
  end
  inspectionFailures.byRegistration[failure.registrationId] = failure
  return failure
end

local function failuresFor(eventState)
  local stored = inspectionFailures
  if stored and stored.event == eventState and stored.stage == progress.stage(eventState) then return stored.byRegistration end
end

local function eligibleVehicle(inventoryId)
  local inventory = overhaul_career_garage_inventory
  local vehicle = inventory and inventory.getVehicle(inventoryId)
  return vehicle and vehicle.owned ~= false and not vehicle.loanType and not vehicle.rental
    and not vehicle.timeToAccess and not vehicle.listedForAuction and vehicle or nil
end

function M.discover(eventState)
  eventState = eventState or currentEvent
  local rows = {}
  for _, nearby in ipairs(interactions.nearbyInventoryIds(eventState)) do
    local vehicle = eligibleVehicle(nearby.inventoryId)
    if vehicle then
      local info, err = classes.inspect(nearby.inventoryId, nearby.vehicleId)
      rows[#rows + 1] = {inventoryId = nearby.inventoryId, vehicleId = nearby.vehicleId,
        name = overhaul_career_garage_inventory.getVehicleNiceNameTranslated(nearby.inventoryId) or vehicle.niceName or vehicle.model,
        model = info and info.model or vehicle.model, distance = nearby.distance,
        traits = info and info.traits, available = info ~= nil, error = err}
      rows[#rows].availabilityKind = info and 'here' or 'notEligible'
    end
  end
  return rows
end

function M.getState(eventState)
  eventState = eventState or currentEvent
  local leagues = classes.leagues(eventState)
  local wallet = balance()
  local offered = {}
  for _, league in ipairs(leagues) do
    league.classes = {}
    for _, class in ipairs(catalog.listClasses(league.id, eventState)) do
      if definitions.accepts(class, eventState) then
        local people, count = {}, 0
        for _, driver in ipairs(catalog.drivers(class.id, eventState)) do
          local person = catalog.opponentIdentity(driver, class)
          local path = '/vehicles/' .. driver.model .. '/' .. driver.config .. '.pc'
          if not people[person] and (not FS or FS:fileExists(path)) then people[person], count = true, count + 1 end
        end
        class.available = count >= definitions.event(eventState).opponentCount
        class.availableOpponents = count
        class.unavailableReason = not class.available and ('Opponent field incomplete: ' .. count .. ' of ' .. definitions.event(eventState).opponentCount .. ' configs available.') or nil
        league.classes[#league.classes + 1] = class
      end
    end
    if #league.classes > 0 then
      -- One entry per class bounds the possible totals. Payment owns whether
      -- these costs require wallet funds, including Freeroam+ and cheats.
      league.affordableEntries = {}
      for entries = 1, #league.classes do
        league.affordableEntries[entries] = overhaul_career_economy_payment.canPay({money = {amount = entries * league.fee, canBeNegative = false}})
      end
      offered[#offered + 1] = league
    end
  end
  leagues = offered
  local nearby = M.discover(eventState)
  for _, car in ipairs(nearby) do
    car.eligibleClassIds, car.classEligibility = {}, {}
    for _, league in ipairs(leagues) do
      for _, class in ipairs(league.classes) do
        local blockers = car.available and classes.blockers(league.id, class.id, car.traits, eventState) or nil
        local eligible = car.available and not blockers
        car.classEligibility[class.id] = {eligible = eligible, reason = blockers and blockers[1] or (not car.available and car.error) or nil,
          reasons = requirementReasons(blockers)}
        if eligible then car.eligibleClassIds[#car.eligibleClassIds + 1] = class.id end
      end
    end
  end
  local vehicles, present = {}, {}
  for _, car in ipairs(nearby) do vehicles[#vehicles + 1], present[car.inventoryId] = car, true end
  local inventory = overhaul_career_garage_inventory
  for id in pairs(inventory and inventory.getVehicles and inventory.getVehicles() or {}) do
    local car = not present[id] and eligibleVehicle(id)
    if car then vehicles[#vehicles + 1] = {inventoryId = id, name = vehicleName({inventoryId = id, model = car.model}),
      model = car.model, available = false, availabilityKind = 'notHere', error = 'Bring it to registration.'} end
  end
  table.sort(vehicles, function(a, b)
    if a.distance ~= b.distance then return (a.distance or math.huge) < (b.distance or math.huge) end
    local left, right = tonumber(a.inventoryId), tonumber(b.inventoryId)
    if left and right then return left < right end
    return tostring(a.inventoryId) < tostring(b.inventoryId)
  end)
  return {nearby = nearby, vehicles = vehicles, leagues = leagues, balance = wallet, registrations = eventState and eventState.registrations or {},
    atRegistration = interactions.isAtRegistration(eventState), paid = eventState and eventState.registrationPaid == true or false,
    totalFee = eventState and eventState.registrationFee or 0, refundTotal = eventState and eventState.registrationRefundTotal or 0,
    nearbyRadius = interactions.nearbyRadius(eventState)}
end

function M.begin(eventState)
  if currentEvent ~= eventState then inspectionFailures = nil end
  currentEvent = eventState
  if eventState then eventState.registrations = eventState.registrations or {} end
  return M.getState(eventState)
end

function M.checkInState(eventState)
  local rows, nearby = {}, {}
  for _, candidate in ipairs(interactions.nearbyInventoryIds(eventState)) do nearby[candidate.inventoryId] = candidate.vehicleId end
  local playerId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  local failures = failuresFor(eventState) or {}
  for _, row in ipairs(eventState and eventState.registrations or {}) do
    if needsInspection(eventState, row) then
      rows[#rows + 1] = {inventoryId = row.inventoryId, registrationId = progress.inspectionKey(row),
        name = vehicleName(row), className = row.declaredClassName,
        inspected = progress.inspected(eventState, row),
        presence = not nearby[row.inventoryId] and 'notHere' or nearby[row.inventoryId] == playerId and 'here' or 'onTrailer',
        failure = failures[progress.inspectionKey(row)]}
    end
  end
  return {atCheckIn = eventState ~= nil and interactions.isAtCheckIn(eventState) or false, entries = rows}
end

function M.checkIn(eventState)
  if not eventState or eventState.phase == 'registration' or eventState.phase == 'complete' then return {ok = false, error = 'No racing session is available for check-in.'} end
  local gate = progress.inspectionGate(eventState)
  if not gate.allowed then return {ok = false, error = gate.message} end
  if not interactions.isAtCheckIn(eventState) then return {ok = false, error = 'Park in the check-in space and stop with your registered cars nearby.'} end
  local nearby = {}
  for _, candidate in ipairs(interactions.nearbyInventoryIds(eventState)) do nearby[candidate.inventoryId] = candidate.vehicleId end
  local inspected = {}
  for _, row in ipairs(eventState.registrations or {}) do
    local vehicleId = nearby[row.inventoryId]
    if vehicleId and needsInspection(eventState, row) then
      if not eligibleVehicle(row.inventoryId) then return inspectionFailure(eventState, row, 'Your registered car is unavailable.') end
      local vehicle = be:getObjectByID(vehicleId)
      local reason, code = roster.mismatchReason(row, vehicle)
      if reason then
        reason = inspectionInstructions[code] or reason
        local failure = inspectionFailure(eventState, row, reason, code)
        if code == 'configuration_changed' then failure.partChanges = roster.partChanges(row, vehicle) end
        return failure
      end
      local info, err = classes.inspect(row.inventoryId, vehicleId)
      if not info then return inspectionFailure(eventState, row, err or 'Unable to inspect this car.') end
      local valid, why = classes.canEnter(row.leagueId, row.declaredClassId, info.traits, eventState)
      if not valid then return inspectionFailure(eventState, row, why) end
      inspected[#inspected + 1] = progress.inspectionKey(row)
    end
  end
  if #inspected == 0 then return {ok = false, error = 'Bring your registered cars near the check-in space, including cars carried on a trailer.'} end
  if not progress.checkedIn(eventState) then eventState.checkIn = {stage = progress.stage(eventState), inspections = {}} end
  eventState.checkIn = eventState.checkIn or {stage = progress.stage(eventState), inspections = {}}
  eventState.checkIn.inspections = eventState.checkIn.inspections or {}
  local failures = failuresFor(eventState)
  for _, id in ipairs(inspected) do
    eventState.checkIn.inspections[id] = true
    if failures then failures[id] = nil end
  end
  local complete = true
  for _, row in ipairs(eventState.registrations or {}) do
    if needsInspection(eventState, row) and not progress.inspected(eventState, row) then complete = false end
  end
  if complete then require('overhaul/events/motorsportEvents/notify')('All cars passed inspection.', 'good', 6) end
  return {ok = true, complete = complete, inspectedCount = #inspected}
end

function M.submit(eventState, selectedRows)
  if not eventState or eventState.phase ~= 'registration' then return {ok = false, error = 'Registration is closed.'} end
  if not interactions.isAtRegistration(eventState) then return {ok = false, error = 'Park in the registration space and stop to enter your vehicles.'} end
  if type(selectedRows) ~= 'table' or #selectedRows == 0 then return {ok = false, error = 'Select a vehicle, league, and class first.'} end
  local nearby, leagues, rows, seen, enteredClasses, total = {}, {}, {}, {}, {}, 0
  local registered, additions = {}, {}
  for _, row in ipairs(eventState.registrations or {}) do
    registered[tostring(row.inventoryId) .. ':' .. row.leagueId .. ':' .. row.declaredClassId] = true
    enteredClasses[row.declaredClassId] = true
  end
  for _, selection in ipairs(selectedRows) do
    local key = type(selection) == 'table' and tostring(selection.inventoryId) .. ':' .. tostring(selection.leagueId) .. ':' .. tostring(selection.classId)
    if not registered[key] then additions[#additions + 1] = selection end
  end
  if #additions == 0 then return {ok = true, registrations = eventState.registrations or {}} end
  for _, vehicle in ipairs(interactions.nearbyInventoryIds(eventState)) do nearby[tostring(vehicle.inventoryId)] = vehicle end
  for _, league in ipairs(classes.leagues(eventState)) do leagues[league.id] = league end
  for _, selection in ipairs(additions) do
    local candidate = type(selection) == 'table' and nearby[tostring(selection.inventoryId)]
    local league = type(selection) == 'table' and leagues[selection.leagueId]
    if not candidate or not eligibleVehicle(candidate.inventoryId) then return {ok = false, error = 'Bring each entered vehicle near registration.'} end
    if not league then return {ok = false, error = 'Choose a valid league for each vehicle.'} end
    local declared = catalog.getClass(selection.classId, eventState)
    if not declared or declared.leagueId ~= league.id or not definitions.accepts(declared, eventState) then return {ok = false, error = 'Choose a class in the selected league.'} end
    if enteredClasses[declared.id] then return {ok = false, error = 'Only one vehicle per entrant per class'} end
    enteredClasses[declared.id] = true
    local key = tostring(candidate.inventoryId) .. ':' .. league.id .. ':' .. declared.id
    if seen[key] then return {ok = false, error = 'This car is already entered in that class.'} end
    seen[key] = true
    local info, err = classes.inspect(candidate.inventoryId, candidate.vehicleId)
    if not info then return {ok = false, error = err or 'An entered vehicle is unavailable.'} end
    local eligible, reason = classes.canEnter(league.id, declared.id, info.traits, eventState)
    if not eligible then return {ok = false, error = reason or 'This vehicle cannot enter the declared class.'} end
    local field = catalog.drivers(declared.id, eventState)
    local count = definitions.event(eventState).opponentCount
    local distinct, available = {}, 0
    for _, driver in ipairs(field) do
      local person = catalog.opponentIdentity(driver, declared)
      if not distinct[person] then
        distinct[person], available = true, available + 1
        local path = '/vehicles/' .. tostring(driver.model) .. '/' .. tostring(driver.config) .. '.pc'
        if FS and not FS:fileExists(path) then return {ok = false, error = 'Opponent config is missing: ' .. path} end
        if available == count then break end
      end
    end
    if available < count then return {ok = false, error = 'This class needs at least ' .. count .. ' distinct available opponents.'} end
    rows[#rows + 1] = {id = 'player-' .. tostring(candidate.inventoryId), registrationId = 'player-' .. key, inventoryId = candidate.inventoryId,
      model = info.model, vehicleName = vehicleName({inventoryId = candidate.inventoryId, model = info.model}),
      config = info.config, traits = info.traits, leagueId = league.id,
      declaredClassId = declared.id, declaredClassName = declared.name, indexSeconds = declared.indexSeconds,
      fee = league.fee, player = true, name = 'You', paid = true, qualifyingLimit = definitions.event(eventState).qualifyingAttempts}
    total = total + league.fee
  end
  local payment = overhaul_career_economy_payment
  local price = {money = {amount = total, canBeNegative = false}}
  if not payment or not payment.canPay(price) then return {ok = false, error = 'You cannot afford these entry fees.'} end
  if not payment.pay(price, {label = (eventState.name or 'Motorsport event') .. ' registration', category = 'service', tags = {'motorsport', 'registration'}}) then
    return {ok = false, error = 'The registration payment failed.'}
  end
  eventState.registrations = eventState.registrations or {}
  for _, row in ipairs(rows) do eventState.registrations[#eventState.registrations + 1] = row end
  eventState.registrationFee, eventState.registrationPaid = (eventState.registrationFee or 0) + total, true
  currentEvent = eventState
  return {ok = true, registrations = eventState.registrations}
end

function M.refund(eventState, row, reason)
  if not eventState or not row or not row.paid then return {ok = false, error = 'This entry has no paid registration.'} end
  if row.refundPaid then return {ok = true} end
  local fee = tonumber(row.fee)
  if not fee or fee < 0 then return {ok = false, error = 'The entry fee is unavailable.'} end
  local payment = overhaul_career_economy_payment
  if not payment or not payment.reward({money = {amount = fee, canBeNegative = false}},
    {label = (eventState.name or 'Motorsport event') .. ' registration refund', category = 'refund', tags = {'motorsport', 'registration', 'refund'}}, true) then
    return {ok = false, error = 'The registration refund failed.'}
  end
  row.refundPaid, row.refundReason = true, reason
  eventState.registrationFee = math.max(0, (eventState.registrationFee or 0) - fee)
  eventState.registrationRefundTotal = (eventState.registrationRefundTotal or 0) + fee
  return {ok = true}
end

return M
