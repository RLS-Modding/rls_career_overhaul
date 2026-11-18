-- Owns weekend stage transitions and check-in gates.
-- weekend.lua owns class state; weekendSchedule.lua and sessionTiming.lua provide calendar decisions.
local M = {}
local definitions = require('overhaul/events/motorsportEvents/definitions')
local weekend = require('overhaul/events/motorsportEvents/weekend')
local qualifying = require('overhaul/events/motorsportEvents/drag/qualifying')
local calendar = require('overhaul/events/motorsportEvents/weekendSchedule')
local bracket = require('overhaul/events/motorsportEvents/drag/bracket')
local timing = require('overhaul/events/motorsportEvents/sessionTiming')
local eventClock = require('overhaul/events/motorsportEvents/eventClock')

function M.enabled(eventState) return eventState ~= nil and eventState.formatVersion == 2 and eventState.roundRotation == true end

function M.stage(eventState)
  if eventState.phase == 'registration' then return 'registration' end
  return eventState.weekendStage or (eventState.phase == 'eliminations' and 'eliminations' or 'qualifying')
end

function M.spectatorOnly(eventState)
  if not M.enabled(eventState) or eventState.phase == 'registration' or eventState.phase == 'complete' or eventState.pendingRefund or M.stage(eventState) == 'qualifying' then return false end
  local classes = eventState.classes or {}
  if #classes == 0 then return false end
  for _, class in ipairs(classes) do
    if class.phase ~= 'complete' then
      for _, entrant in ipairs(class.entrants or {}) do
        if entrant.player and not entrant.qualifying then return false end
        if entrant.player and entrant.qualifying and entrant.qualifying.valid then
          if not class.bracket then return false end
          local outcome = bracket.playerOutcome(class.bracket, entrant.id)
          if not outcome or outcome == 'Advancing' or outcome == 'Third-place race next' then return false end
        end
      end
    end
  end
  return true
end

function M.checkedIn(eventState)
  local sameRaceDay = eventState and timing.enabled(eventState) and eventState.checkIn and eventState.checkIn.stage == 'eliminations'
    and M.stage(eventState) == 'finals' and definitions.event(eventState).stages.eliminations.day == definitions.event(eventState).stages.finals.day
  return eventState ~= nil and (eventState.checkInVersion ~= 1 or eventState.checkIn ~= nil and (eventState.checkIn.stage == M.stage(eventState) or sameRaceDay)
    and (not eventState.checkIn.spectatorOnly or M.spectatorOnly(eventState)))
end

function M.inspected(eventState, row)
  return eventState.checkInVersion ~= 1 or M.checkedIn(eventState) and eventState.checkIn.inspections ~= nil
    and eventState.checkIn.inspections[M.inspectionKey(row)] == true
end

function M.inspectionKey(row)
  return row.registrationId or (row.id or 'player-' .. tostring(row.inventoryId)) .. ':' .. tostring(row.leagueId)
end

function M.completeRegistrationInspection(eventState)
  if not eventState or eventState.checkInVersion ~= 1 or not eventState.registrationPaid or eventState.phase == 'complete' or M.stage(eventState) ~= 'qualifying' then return end
  local inspections = {}
  for _, row in ipairs(eventState.registrations or {}) do
    if not row.excluded and not row.refundPaid then inspections[M.inspectionKey(row)] = true end
  end
  eventState.checkIn = {stage = 'qualifying', inspections = inspections}
end

function M.initialize(eventState, fresh)
  if not eventState or eventState.formatVersion ~= 2 or eventState.roundRotation == false then return end
  eventState.roundRotation = true
  local initialized, error
  if fresh then initialized, error = calendar.begin(eventState) else initialized, error = calendar.ensure(eventState) end
  eventState.checkInVersion = 1
  eventState.weekendStage = M.stage(eventState)
  return initialized, error
end

local function identity(eventState)
  return table.concat({M.stage(eventState), eventState.phase, tostring(eventState.activeClassId or eventState.activeRegistrationId),
    tostring(eventState.bracket and eventState.bracket.currentRound)}, ':')
end

local function advance(eventState)
  if not M.enabled(eventState) or eventState.phase == 'registration' or eventState.phase == 'complete' then return {ok = true, changed = false} end
  if eventState.pendingRefund then return {ok = false, error = 'Waiting for the entry fee refund.'} end
  local before, stage = identity(eventState), M.stage(eventState)
  if stage == 'qualifying' then
    weekend.sync(eventState)
    local nextClass = weekend.prepareNext(eventState, {stage = stage, rotate = true})
    if not nextClass.ok then return nextClass end
    if not nextClass.stageComplete then return {ok = true, changed = identity(eventState) ~= before} end
    local seeded = weekend.seedBrackets(eventState)
    if not seeded.ok then return seeded end
    eventState.weekendStage, stage = 'eliminations', 'eliminations'
  end
  for _, class in ipairs(eventState.classes or {}) do
    if not class.bracket or not eventState.championshipPlanned then
      local seeded = weekend.seedBrackets(eventState)
      if not seeded.ok then return seeded end
      break
    end
  end
  if stage == 'eliminations' then
    weekend.sync(eventState)
    local nextClass = weekend.prepareNext(eventState, {stage = stage, rotate = true})
    if not nextClass.ok then return nextClass end
    if not nextClass.stageComplete then return {ok = true, changed = identity(eventState) ~= before} end
    eventState.weekendStage, stage = 'finals', 'finals'
  end
  local nextClass = weekend.prepareNext(eventState, {stage = stage, rotate = true})
  if not nextClass.ok and nextClass.blocked and stage == 'finals' then
    eventState.weekendStage = 'eliminations'
    nextClass = weekend.prepareNext(eventState, {stage = 'eliminations', rotate = true})
  end
  if not nextClass.ok then return nextClass end
  return {ok = true, changed = identity(eventState) ~= before, stageComplete = nextClass.stageComplete}
end

function M.advance(eventState)
  local state = eventState and eventState.weekendCalendar
  local previousDay = eventState and definitions.event(eventState).stages[M.stage(eventState)].day
  local _, previousKey
  if state then _, previousKey = timing.opening(eventState, M.stage(eventState), state.anchorDay) end
  previousKey = eventState and eventState.scheduledGroupKey or previousKey
  local result = advance(eventState)
  if result.ok and previousDay then eventClock.transitionDay(eventState, previousDay, definitions.event(eventState).stages[M.stage(eventState)].day) end
  if result.ok and state and eventState.phase ~= 'complete' then
    timing.transition(eventState, M.stage(eventState), previousKey, calendar.worldMinutes(), state.anchorDay)
    local _, key = timing.opening(eventState, M.stage(eventState), state.anchorDay)
    eventState.scheduledGroupKey = key
  end
  return result
end

function M.gate(eventState, claimed)
  if not M.enabled(eventState) or eventState.phase == 'complete' then return {allowed = true, waiting = false} end
  return calendar.gate(eventState, M.stage(eventState), claimed)
end

function M.inspectionGate(eventState)
  local gate = M.gate(eventState)
  if gate.realTime or not gate.scheduled or not gate.clockReady then return gate end
  local event = definitions.event(eventState)
  gate.requiredWorldMinute = gate.requiredCareerDay * 1440 + (event.stages.registration.minuteOfDay or 0)
  local effective = math.max(gate.currentWorldMinute, eventState.weekendCalendar.highestMinute or gate.currentWorldMinute)
  gate.waitMinutes = math.max(0, gate.requiredWorldMinute - effective)
  gate.allowed, gate.waiting = gate.waitMinutes == 0, gate.waitMinutes > 0
  gate.message = gate.allowed and 'Inspection is open. Racing begins at its scheduled time.'
    or ('Inspection opens at ' .. timing.format(gate.requiredWorldMinute) .. ' on event day ' .. gate.requiredDay .. '.')
  return gate
end

local function canAdvanceDay(eventState, gate)
  if gate.realTime then return false end
  if not M.enabled(eventState) or eventState.phase == 'registration' and not gate.scheduled or eventState.phase == 'complete' or eventState.pendingRefund
    or eventState.inFlight or gate.claimed or not gate.clockReady or gate.allowed then return false end
  if gate.scheduled then
    if not gate.waitMinutes or gate.waitMinutes <= 0 then return false end
  elseif not gate.waitDays or gate.waitDays <= 0 then return false end
  local weather = overhaul_world_weather
  if not weather or not weather.getDayNightCycle or not weather.sleepTo then return false end
  if weather.isExternalOverrideActive and weather.isExternalOverrideActive() then return false end
  local cycle = weather.getDayNightCycle()
  return type(cycle) == 'table' and (gate.scheduled or cycle.play == false) and type(cycle.time) == 'number'
    and cycle.time == cycle.time and cycle.time >= 0 and cycle.time <= 1
end

function M.canAdvanceDay(eventState) return canAdvanceDay(eventState, M.gate(eventState)) end

function M.advanceDay(eventState)
  local gate = M.gate(eventState)
  if not canAdvanceDay(eventState, gate) then return {ok = false, error = 'Time advance is unavailable while racing or when the next session is already open.'} end
  local weather = overhaul_world_weather
  if gate.scheduled then
    local before, target = calendar.worldMinutes(), gate.requiredWorldMinute
    -- sleepTo advances to the next occurrence of a clock time, without changing
    -- playCycle. Walk whole days first so an arbitrary future target is exact.
    local count = 0
    while before and target - before > 0.01 do
      count = count + 1
      if count > 32 then return {ok = false, error = 'The scheduled time is too far away to advance safely.'} end
      local nextMinute = math.min(target, before + 1440)
      if weather.sleepTo((nextMinute % 1440 / 1440 + .5) % 1) ~= true then
        return {ok = false, error = 'The career calendar could not advance.'}
      end
      local after = calendar.worldMinutes()
      if not after or after <= before then return {ok = false, error = 'The career calendar did not advance.'} end
      before = after
    end
    if not M.gate(eventState).allowed then return {ok = false, error = 'The next scheduled group is still unavailable.'} end
    return {ok = true, worldMinute = before}
  end
  local minute = weather.getWorldMinutes() % 1440
  local target = (minute / 1440 + .5) % 1
  for _ = 1, gate.waitDays do
    if weather.sleepTo(target) ~= true then return {ok = false, error = 'The career calendar could not advance.'} end
  end
  if not M.gate(eventState).allowed then return {ok = false, error = 'The next event day is still unavailable.'} end
  eventState.checkIn, eventState.venueArrivalDay = nil, nil
  return {ok = true}
end

local function registration(eventState)
  for _, row in ipairs(eventState.registrations or {}) do
    if eventState.activeRegistrationId and row.registrationId == eventState.activeRegistrationId
      or eventState.activeClassId and row.classId == eventState.activeClassId then return row end
  end
end

function M.resume(eventState)
  if not M.enabled(eventState) then return {ok = true, changed = false} end
  if eventState.phase == 'eliminations' then return M.advance(eventState) end
  if eventState.phase == 'playerQualifying' or eventState.phase == 'qualifying' then
    local row, info = registration(eventState), qualifying.roundInfo(eventState.entrants)
    local key = eventState.activeClassId or row and row.declaredClassId
    local class = eventState.qualifyingSchedule and eventState.qualifyingSchedule.classes and eventState.qualifyingSchedule.classes[key]
    local current = class and class.rounds[tostring(info.number)]
    local previous = class and class.rounds[tostring(info.number - 1)]
    if info.complete or previous and previous.complete and not current then return M.advance(eventState) end
  end
  return {ok = true, changed = false}
end

local function field(eventState, row)
  for _, session in ipairs(eventState.classes or {}) do if session.id == row.classId then return session.entrants end end
  local rows = {row}
  for _, opponent in ipairs(row.qualifyingOpponents or {}) do rows[#rows + 1] = opponent end
  return rows
end

local function nextRegistration(eventState, current)
  local selected, lowest
  for _, row in ipairs(eventState.registrations or {}) do
    if row ~= current and not row.excluded then
      local info = qualifying.roundInfo(field(eventState, row))
      if not info.complete and (not lowest or info.number < lowest) then selected, lowest = row, info.number end
    end
  end
  if selected then return selected end
  if current and not qualifying.roundInfo(field(eventState, current)).complete then return current end
end

local function vehicleName(row)
  return row and (row.vehicleName or row.model or ('Vehicle #' .. tostring(row.inventoryId)))
end

function M.session(eventState, claimed)
  if not M.enabled(eventState) then return nil end
  local gate, current = M.gate(eventState, claimed), registration(eventState)
  local waiting = gate.waiting == true and eventState.phase ~= 'complete'
  local nextEntry = waiting and current or M.stage(eventState) == 'qualifying' and nextRegistration(eventState, current)
  local label = eventState.phase == 'complete' and 'Event complete' or gate.label
  if waiting and gate.clockReady then
    label = gate.scheduled and ('Waiting for ' .. (gate.label or 'next group'))
      or M.stage(eventState) == 'finals' and 'Eliminations complete' or 'Qualifying complete'
  end
  if waiting and not gate.clockReady then label = 'Waiting for career calendar' end
  local info = qualifying.roundInfo(eventState.entrants)
  local weather = overhaul_world_weather
  local cycle = weather and weather.getDayNightCycle and weather.getDayNightCycle()
  return {day = eventState.phase == 'complete' and definitions.totalDays(eventState) or gate.weekendDay or 1, totalDays = definitions.totalDays(eventState), stage = M.stage(eventState), label = label,
    waiting = waiting, available = gate.allowed == true, clockReady = gate.clockReady,
    checkedIn = M.checkedIn(eventState), spectatorOnly = M.spectatorOnly(eventState),
    inspectionAvailable = eventState.phase ~= 'registration' and eventState.phase ~= 'complete' and M.inspectionGate(eventState).allowed,
    checkInRequired = eventState.phase ~= 'registration' and eventState.phase ~= 'complete' and not M.spectatorOnly(eventState) and not M.checkedIn(eventState),
    canAdvanceDay = canAdvanceDay(eventState, gate),
    scheduledWorldMinute = gate.requiredWorldMinute, currentWorldMinute = gate.currentWorldMinute,
    waitMinutes = gate.waitMinutes, clockFrozen = cycle and cycle.play == false or false,
    realTime = gate.realTime, remainingSeconds = gate.remainingSeconds,
    advanceLabel = gate.scheduled and (gate.waitDays > 0 and 'Advance to next session' or 'Skip to my group') or 'Advance Day',
    targetTimeLabel = gate.targetTimeLabel,
    nextDay = waiting and gate.requiredDay, nextLabel = waiting and gate.label,
    currentClassName = eventState.className, currentVehicleName = vehicleName(current),
    nextClassName = nextEntry and (nextEntry.declaredClassName or nextEntry.className), nextVehicleName = vehicleName(nextEntry),
    nextPlayerCall = not waiting and M.stage(eventState) == 'qualifying' and nextEntry ~= nil and current ~= nil
      and qualifying.attemptCount(current) >= info.number,
    message = gate.message}
end

return M
