-- Owns weekend calendar days and round ordering.
-- definitions.lua supplies authored stages; weekendProgress.lua consumes the resulting schedule.
local M = {}
local definitions = require('overhaul/events/motorsportEvents/definitions')
local timing = require('overhaul/events/motorsportEvents/sessionTiming')
local eventClock = require('overhaul/events/motorsportEvents/eventClock')

local function integer(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge and value == math.floor(value)
end

local function worldMinutes()
  local weather = overhaul_world_weather
  if not weather or type(weather.getWorldMinutes) ~= 'function' then return nil end
  if type(weather.getCalendarState) == 'function' then
    local ready, state = pcall(weather.getCalendarState)
    if not ready or type(state) ~= 'table' or state.ready ~= true then return nil end
  end
  local ok, minutes = pcall(weather.getWorldMinutes)
  if not ok or type(minutes) ~= 'number' or minutes ~= minutes or minutes < 0 or minutes == math.huge then return nil end
  return minutes
end
M.worldMinutes = worldMinutes
local function careerDay()
  local minutes = worldMinutes()
  return minutes and math.floor(minutes / 1440)
end

local function progressDay(eventState)
  local stages = definitions.event(eventState).stages
  if stages[eventState.weekendStage] then return stages[eventState.weekendStage].day end
  local day = 1
  local function championshipSize(session)
    local size = session.championshipFieldSize
    if session == eventState then
      for _, class in ipairs(type(eventState.classes) == 'table' and eventState.classes or {}) do
        if eventState.activeClassId and class.id == eventState.activeClassId then size = class.championshipFieldSize or size; break end
      end
    end
    return size or eventState.championshipFieldSize or definitions.event(eventState).finalsFieldSize
  end
  local function visit(session)
    if type(session) ~= 'table' then return end
    local bracket = type(session.bracket) == 'table' and session.bracket or nil
    if session.phase == 'complete' or session.winnerId or session.rewardPaid
      or bracket and (bracket.winnerId or bracket.complete) then day = stages.finals.day; return end
    if session.phase == 'eliminations' or type(bracket) == 'table' then
      day = math.max(day, stages.eliminations.day)
      local round = bracket and bracket.rounds and bracket.rounds[bracket.currentRound or 1]
      local matches = round and round.matches
      if type(matches) == 'table' and #matches > 0 and #matches * 2 <= championshipSize(session) then day = stages.finals.day end
    end
  end
  visit(eventState)
  for _, session in ipairs(type(eventState.classes) == 'table' and eventState.classes or {}) do visit(session) end
  return day
end

local function calendar(eventState, fresh, today)
  if type(eventState) ~= 'table' then return nil, 'No event is scheduled.' end
  local state = eventState.weekendCalendar
  if state ~= nil then
    if type(state) ~= 'table' or state.version ~= 1 or not integer(state.anchorDay)
      or not integer(state.highestDay) or state.highestDay < 0 or state.highestDay < state.anchorDay then
      return nil, 'The saved weekend calendar is unavailable.'
    end
    if today and today > state.highestDay then state.highestDay = today end
    return state
  end
  if today == nil then return nil, 'Waiting for the career calendar to load.' end
  local anchor = today
  if not fresh then
    anchor = today - progressDay(eventState) + 1
    if integer(eventState.eventDay) and eventState.eventDay >= 0 then anchor = math.min(anchor, eventState.eventDay) end
  end
  state = {version = 1, anchorDay = anchor, highestDay = today}
  eventState.weekendCalendar = state
  return state
end

function M.begin(eventState)
  eventClock.ensureDay(eventState, progressDay(eventState))
  return calendar(eventState, true, careerDay())
end
function M.ensure(eventState)
  eventClock.ensureDay(eventState, progressDay(eventState))
  return calendar(eventState, false, careerDay())
end

function M.gate(eventState, stage, claimed)
  local minutes = worldMinutes()
  local definition, today = definitions.event(eventState).stages[stage], minutes and math.floor(minutes / 1440)
  local totalDays = definitions.totalDays(eventState)
  local state, err = calendar(eventState, false, today)
  local info = {stage = stage, requiredDay = definition and definition.day, careerDay = today,
    clockReady = today ~= nil, allowed = false, claimed = claimed == true, label = definition and definition.label}
  if state then
    if minutes and timing.enabled(eventState) then state.highestMinute = math.max(state.highestMinute or minutes, minutes) end
    local effective = math.max(today or state.highestDay, state.highestDay)
    local elapsed = effective - state.anchorDay + 1
    info.anchorDay, info.weekendDay = state.anchorDay, math.max(1, math.min(totalDays, elapsed))
    info.rewound, info.late = today ~= nil and today < state.highestDay, elapsed > totalDays
    if definition then
      info.requiredCareerDay = state.anchorDay + definition.day - 1
      info.waitDays = math.max(0, info.requiredCareerDay - effective)
      if timing.enabled(eventState) then
        info.scheduled = true
        info.currentWorldMinute = minutes
        info.requiredWorldMinute = timing.opening(eventState, stage, state.anchorDay)
        info.waitMinutes = math.max(0, info.requiredWorldMinute - (state.highestMinute or minutes or 0))
        info.rewound = info.rewound or minutes ~= nil and minutes < (state.highestMinute or minutes)
        info.targetTimeLabel = 'Day ' .. (math.floor(info.requiredWorldMinute / 1440) - state.anchorDay + 1)
          .. ' at ' .. timing.format(info.requiredWorldMinute)
      end
    end
  end
  if not definition then info.message = 'This event stage is unavailable.'
  elseif type(eventState) ~= 'table' then info.message = err
  elseif claimed == true then
    info.allowed, info.message = true, 'The prepared heat can finish.'
  elseif today == nil or not state then info.message = err or 'Waiting for the career calendar to load.'
  elseif info.waitDays == 0 and (not info.waitMinutes or info.waitMinutes == 0) then
    info.allowed = true
    info.message = definition.label .. ', day ' .. info.weekendDay .. '/' .. totalDays
  else
    info.message = definition.label .. ' opens on Day ' .. definition.day .. ', in ' .. info.waitDays
      .. ' career day' .. (info.waitDays == 1 and '' or 's') .. '. Sleep or come back then.'
  end
  if not info.allowed and info.scheduled and info.clockReady then
    info.message = definition.label .. ' opens ' .. info.targetTimeLabel .. '. Wait or skip ahead; your entry is held.'
  end
  if eventClock.frozen() and definition and state and info.clockReady then
    local realTime = eventClock.ensureDay(eventState, progressDay(eventState))
    info.realTime, info.scheduled, info.weekendDay = true, false, definition.day
    info.remainingSeconds = realTime.day == definition.day and math.max(0, (realTime.readyAt or 0) - eventClock.now()) or 0
    info.allowed = claimed == true or info.remainingSeconds == 0
    info.waitDays, info.waitMinutes, info.targetTimeLabel = 0, nil, nil
    info.requiredWorldMinute = nil
    info.message = info.allowed and (definition.label .. ', day ' .. definition.day .. '/' .. totalDays)
      or ('Day ' .. definition.day .. ' opens in ' .. math.ceil(info.remainingSeconds / 60) .. ' real minutes. Your entry is held.')
  end
  info.waiting = not info.allowed
  return info
end

return M
