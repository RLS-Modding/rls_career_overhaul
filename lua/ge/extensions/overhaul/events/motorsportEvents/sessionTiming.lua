-- Owns scheduled session clock gates.
-- weekendSchedule.lua supplies the calendar and eventClock.lua supplies frozen-calendar time.
-- Reads never move a deadline or consume a race.
local M = {}
local definitions = require('overhaul/events/motorsportEvents/definitions')
local qualifying = require('overhaul/events/motorsportEvents/drag/qualifying')
function M.enabled(eventState)
  local schedule = eventState and definitions.event(eventState).schedule
  return type(schedule) == 'table' and schedule.version == 1
end
local function activeClassId(eventState)
  if eventState.activeClassId then return eventState.activeClassId end
  for _, row in ipairs(eventState.registrations or {}) do
    if row.registrationId == eventState.activeRegistrationId and eventState.activeRegistrationId then
      return row.classId or row.declaredClassId
    end
  end
  for _, entrant in ipairs(eventState.entrants or {}) do
    if entrant.player then return entrant.classId or entrant.declaredClassId end
  end
end
local function order(eventState)
  local ids, seen = {}, {}
  local function add(id)
    if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
  end
  for _, row in ipairs(eventState.registrations or {}) do
    if not row.excluded then add(row.classId or row.declaredClassId) end
  end
  for _, class in ipairs(eventState.classes or {}) do add(class.id) end
  for index, id in ipairs(ids) do
    if id == activeClassId(eventState) then return index - 1, math.max(1, #ids) end
  end
  return 0, math.max(1, #ids)
end
function M.opening(eventState, stage, anchorDay)
  if not M.enabled(eventState) then return nil end
  local event = definitions.event(eventState)
  local definition = event.stages[stage]
  if not definition then return nil end
  local base = (anchorDay + definition.day - 1) * 1440 + (definition.minuteOfDay or 0)
  local index, count = order(eventState)
  local schedule, round = event.schedule, 1
  if stage == 'qualifying' then
    round = qualifying.roundInfo(eventState.entrants).number
    base = base + ((round - 1) * count + index) * schedule.qualifyingGroupMinutes
  elseif stage == 'eliminations' or stage == 'finals' then
    round = eventState.bracket and eventState.bracket.currentRound or 1
    base = base + (round - 1) * schedule.eliminationRoundMinutes + index * schedule.turnaroundMinutes
  end
  local key = table.concat({stage, tostring(activeClassId(eventState) or ''), round}, ':')
  local delayed = eventState.sessionTiming and eventState.sessionTiming.key == key and eventState.sessionTiming.notBefore
  return math.max(base, delayed or base), key
end
function M.format(worldMinute)
  if type(worldMinute) ~= 'number' then return nil end
  local minute = math.floor(worldMinute % 1440)
  return string.format('%02d:%02d', math.floor(minute / 60), minute % 60)
end
-- Called on actual group transitions, never on a UI read.
function M.transition(eventState, stage, previousKey, now, anchorDay)
  if not M.enabled(eventState) or not now or not anchorDay then return end
  local opening, key = M.opening(eventState, stage, anchorDay)
  if opening and previousKey and key ~= previousKey then
    eventState.sessionTiming = {key = key, notBefore = math.max(opening, now + definitions.event(eventState).schedule.turnaroundMinutes)}
  end
end
return M
