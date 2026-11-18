-- Owns bounded progression to the next player group.
-- drag/qualifyingSchedule.lua and drag/simulation.lua resolve NPC heats; the coordinator settles completion.
-- Explicit player-requested catch-up. Never called by a UI read or a background timer.
local M = {}
local definitions = require('overhaul/events/motorsportEvents/definitions')
local qualifying = require('overhaul/events/motorsportEvents/drag/qualifying')
local bracket = require('overhaul/events/motorsportEvents/drag/bracket')
local background = require('overhaul/events/motorsportEvents/background')
local progress = require('overhaul/events/motorsportEvents/weekendProgress')
local weekend = require('overhaul/events/motorsportEvents/weekend')
local calendar = require('overhaul/events/motorsportEvents/weekendSchedule')
local eventClock = require('overhaul/events/motorsportEvents/eventClock')

local function remaining(eventState)
  if eventState.phase == 'qualifying' or eventState.phase == 'playerQualifying' then return true end
  for _, class in ipairs(eventState.classes or {}) do
    if class.phase ~= 'complete' then
      for _, entrant in ipairs(class.entrants or {}) do
        if entrant.player then
          local outcome = bracket.playerOutcome(class.bracket, entrant.id)
          if not outcome or outcome == 'Advancing' or outcome == 'Third-place race next' then return true end
        end
      end
    end
  end
  return false
end

local function advanceClock(target)
  local now = calendar.worldMinutes()
  for _ = 1, 32 do
    if not now then return nil, 'The career clock is unavailable.' end
    if target - now <= .01 then return true end
    local nextMinute = math.min(target, now + 1440)
    if overhaul_world_weather.sleepTo((nextMinute % 1440 / 1440 + .5) % 1) ~= true then
      return nil, 'The career calendar could not advance.'
    end
    local after = calendar.worldMinutes()
    if not after or after <= now then return nil, 'The career calendar did not advance.' end
    now = after
  end
  return nil, 'The next run is too far away to skip safely.'
end

local function pending(eventState)
  local player, opponents = false, 0
  if eventState.phase == 'qualifying' or eventState.phase == 'playerQualifying' then
    local round = qualifying.roundInfo(eventState.entrants).number
    for _, entrant in ipairs(eventState.entrants) do
      if not qualifying.isDone(entrant) and qualifying.attemptCount(entrant) < round then
        if entrant.player then player = true else opponents = opponents + 1 end
      end
    end
    -- A lone opponent paired with the player is never simulated separately.
    if player and opponents <= 1 then opponents = 0 end
  elseif eventState.bracket then
    local players = {}
    for _, entrant in ipairs(eventState.entrants) do if entrant.player then players[entrant.id] = true end end
    local round = eventState.bracket.rounds[eventState.bracket.currentRound]
    for _, match in ipairs(round and round.matches or {}) do
      if not match.winnerId and not match.complete then
        if players[match.a] or players[match.b] then player = true else opponents = opponents + 1 end
      end
    end
  end
  return player, opponents
end

function M.status(eventState, runtime)
  if not eventState or not definitions.event(eventState).schedule or eventState.phase == 'registration' or eventState.phase == 'complete' then return nil end
  local key = table.concat({eventState.id, eventState.phase, eventState.activeClassId or eventState.activeRegistrationId or '',
    eventState.bracket and eventState.bracket.currentRound or qualifying.roundInfo(eventState.entrants or {}).attempts}, ':')
  local player, opponents = pending(eventState)
  local gate = progress.gate(eventState)
  local reason
  local weather = overhaul_world_weather
  if runtime and runtime.playerPass then reason = 'Finish your current pass first.'
  elseif eventState.pendingRefund then reason = 'Waiting for the entry fee refund.'
  elseif not remaining(eventState) then reason = 'You have no remaining runs in this event.'
  elseif gate.allowed and player and opponents == 0 then reason = 'Your group is ready.'
  elseif eventClock.frozen() and not gate.allowed then reason = 'Wait for the next event day to open.'
  elseif not calendar.worldMinutes() or not weather or not eventClock.frozen() and not weather.sleepTo then reason = 'The career clock is unavailable.'
  elseif weather.isExternalOverrideActive and weather.isExternalOverrideActive() then reason = 'Another activity controls the clock.' end
  return {available = reason == nil, reason = reason, key = key}
end

function M.run(eventState, complete)
  local start, simulated = calendar.worldMinutes(), 0
  for _ = 1, 64 do
    if eventState.phase == 'complete' or not remaining(eventState) then
      return {ok = true, noRuns = true, simulated = simulated, advanced = calendar.worldMinutes() > start}
    end
    local gate = progress.gate(eventState)
    if not gate.clockReady then return {ok = false, error = gate.message} end
    if not gate.allowed then
      if gate.realTime then return {ok = false, error = gate.message} end
      local ok, err = advanceClock(gate.requiredWorldMinute)
      if not ok then return {ok = false, error = err} end
    end
    local player, opponents = pending(eventState)
    if opponents > 0 then
      -- Calendar-mode skips include the simulated group's career time.
      local schedule = definitions.event(eventState).schedule
      local minutes = eventState.phase == 'eliminations' and schedule.eliminationRoundMinutes or schedule.qualifyingGroupMinutes
      if not eventClock.frozen() then
        local ok, err = advanceClock(calendar.worldMinutes() + minutes)
        if not ok then return {ok = false, error = err} end
      end
      -- One authored field contains at most 128 opponents; pairs stay atomic.
      for _ = 1, 3 do
        local result = background.step(eventState, 64)
        if result.error then return {ok = false, error = result.error} end
        simulated = simulated + result.count
        if not result.changed or result.count < 64 then break end
      end
      weekend.sync(eventState)
    end
    if player then return {ok = true, simulated = simulated, advanced = calendar.worldMinutes() > start} end
    if eventState.phase == 'eliminations' and eventState.bracket and not bracket.nextMatch(eventState.bracket) then
      complete(eventState)
    else
      local result = progress.advance(eventState)
      if not result.ok then return result end
    end
  end
  return {ok = false, error = 'Catch-up reached its safety limit. Progress is saved; skip again to continue.'}
end

return M
