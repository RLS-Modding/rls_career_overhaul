-- Owns the real-time clock used by frozen-calendar events.
-- offers.lua and sessionTiming.lua consume times; this helper does not advance career weather.
local M = {offerLifetime = 3600, cooldown = 1800}

function M.frozen()
  local weather = overhaul_world_weather
  local cycle = weather and weather.getDayNightCycle and weather.getDayNightCycle()
  return cycle and cycle.play == false or false
end

function M.now() return os.time() end

function M.ensureDay(eventState, day)
  if not eventState.realTimeSchedule then eventState.realTimeSchedule = {day = day} end
  return eventState.realTimeSchedule
end

function M.transitionDay(eventState, previousDay, day)
  if day > previousDay then eventState.realTimeSchedule = {day = day, readyAt = M.now() + M.cooldown} end
end

return M
