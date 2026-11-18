-- Owns bounded offsite event progression.
-- weekendProgress.lua gates sessions; drag/qualifyingSchedule.lua and drag/simulation.lua resolve NPC results.
-- Bounded numerical catch-up for the currently open calendar group.
-- Caller owns runtime safety: no runner/parking claims and no visible paddock.
-- This module never switches classes/rounds, resolves a player heat, or pays money.
local M = {}
local qualifying = require('overhaul/events/motorsportEvents/drag/qualifying')
local qualifyingSchedule = require('overhaul/events/motorsportEvents/drag/qualifyingSchedule')
local bracket = require('overhaul/events/motorsportEvents/drag/bracket')
local classes = require('overhaul/events/motorsportEvents/drag/classes')
local progress = require('overhaul/events/motorsportEvents/weekendProgress')
local MODULUS = 2147483647

local function finite(value)
  local n = tonumber(value)
  return n and n == n and n > 0 and n < math.huge and n or nil
end

local function seed(eventState)
  local value, name = 1, tostring(eventState.id or '')
  for i = 1, #name do value = (value * 31 + name:byte(i)) % MODULUS end
  return math.max(1, value)
end

local function classId(eventState)
  if eventState.activeClassId then return eventState.activeClassId end
  for _, row in ipairs(eventState.registrations or {}) do
    if row.registrationId == eventState.activeRegistrationId
      or row.id and row.leagueId and row.id .. ':' .. row.leagueId == eventState.activeRegistrationId then
      return row.declaredClassId
    end
  end
end

local function randomState(eventState)
  local saved = eventState.backgroundSimulation
  if saved and (saved.version ~= 1 or not finite(saved.rngState)
    or saved.rngState >= MODULUS or saved.rngState ~= math.floor(saved.rngState)) then
    return nil, 'The saved background simulation state is unavailable.'
  end
  return saved and saved.rngState or seed(eventState)
end

local function makeRow(entrant, state)
  local function draw()
    state = (state * 16807) % MODULUS
    return (state - 1) / (MODULUS - 1)
  end
  local base = finite(entrant.estimatedET)
  if not base then
    for _, attempt in ipairs(entrant.qualifyingAttempts or {}) do
      if attempt.valid and not attempt.simulated and not attempt.breakout then
        base = finite(attempt.time)
        if base then break end
      end
    end
  end
  if not base and entrant.qualifying and entrant.qualifying.valid and not entrant.qualifying.breakout then
    base = finite(entrant.qualifying.time)
  end
  local row = {entrantId = entrant.id, simulated = true, valid = base ~= nil}
  local variation, reaction = draw(), draw()
  if base then row.time = base + (variation - .5) * math.min(.24, base * .024)
  else row.reason = 'No measured elapsed-time baseline is available.' end
  row.reaction = .05 + reaction * .2
  return row, state
end

local function commitState(eventState, state)
  eventState.backgroundSimulation = {version = 1, rngState = state}
end

function M.step(eventState, maxResults)
  local out = {changed = false, count = 0, complete = false}
  if not eventState or eventState.formatVersion ~= 2 or eventState.pendingRefund or eventState.phase == 'complete'
    or not eventState.eventDefinition or not eventState.eventDefinition.schedule or eventState.eventDefinition.schedule.version ~= 1 then return out end
  if eventState.phase ~= 'qualifying' and eventState.phase ~= 'playerQualifying' and eventState.phase ~= 'eliminations' then return out end
  if not progress.gate(eventState).allowed then return out end
  local limit = tonumber(maxResults) or 4
  if limit ~= limit or limit < 1 then return out end
  limit = math.min(64, math.floor(limit))
  local key = classId(eventState)
  if not key then out.error = 'The active drag class is unavailable.'; return out end
  local state, stateError = randomState(eventState)
  if not state then out.error = stateError; return out end
  local byId = {}
  for _, entrant in ipairs(eventState.entrants or {}) do byId[tostring(entrant.id)] = entrant end

  if eventState.phase == 'qualifying' or eventState.phase == 'playerQualifying' then
    local info = qualifying.roundInfo(eventState.entrants)
    if info.complete then out.complete = true; return out end
    local reserved, plan, groups, grouped = {}, nil, {}, {}
    if qualifyingSchedule.enabled(eventState) then
      local err
      plan, err = qualifyingSchedule.prepare(eventState, info.number)
      if not plan then out.error = err; return out end
      -- Keep a player's paired opponent unrecorded, otherwise the physical heat
      -- would try to overwrite a simulated attempt on the player's return.
      for _, heat in ipairs(plan.heats) do
        local playerHeat = false
        for _, id in ipairs(heat.ids) do
          local entrant = byId[tostring(id)]
          if not entrant then out.error = 'A scheduled entrant is unavailable.'; return out end
          if entrant.player and not qualifying.isDone(entrant) and qualifying.attemptCount(entrant) < info.number then playerHeat = true end
        end
        if playerHeat then for _, id in ipairs(heat.ids) do reserved[tostring(id)] = true end
        else
          local group = {}
          for _, id in ipairs(heat.ids) do
            group[#group + 1], grouped[tostring(id)] = byId[tostring(id)], true
          end
          groups[#groups + 1] = group
        end
      end
    else
      for _, heat in ipairs(qualifying.roundHeats(eventState.entrants)) do
        local playerHeat = false
        for _, entrant in ipairs(heat.entrants) do if entrant.player then playerHeat = true end end
        if playerHeat then for _, entrant in ipairs(heat.entrants) do reserved[tostring(entrant.id)] = true end
        else
          groups[#groups + 1] = heat.entrants
          for _, entrant in ipairs(heat.entrants) do grouped[tostring(entrant.id)] = true end
        end
      end
    end
    for _, entrant in ipairs(eventState.entrants or {}) do
      if not entrant.player and not reserved[tostring(entrant.id)] and not grouped[tostring(entrant.id)] then
        groups[#groups + 1] = {entrant}
      end
    end
    for _, group in ipairs(groups) do
      if out.count >= limit then break end
      local pending = {}
      for _, entrant in ipairs(group) do
        if not qualifying.isDone(entrant) and qualifying.attemptCount(entrant) == info.number - 1 then
          pending[#pending + 1] = entrant
        end
      end
      -- A physical NPC pair is atomic even when this frame's remaining budget is
      -- smaller, so returning to the venue cannot discover a half-resolved heat.
      if #pending > 0 and out.count + #pending <= limit then
        local rows, nextState = {}, state
        for _, entrant in ipairs(pending) do
          local row; row, nextState = makeRow(entrant, nextState)
          rows[#rows + 1] = row
        end
        local graded, err = classes.applyResult(key, {rows = rows}, 'qualifying', eventState)
        if not graded or not graded.rows or #graded.rows ~= #pending then
          out.error = err or 'Background qualifying grading failed.'; return out
        end
        for i, entrant in ipairs(pending) do qualifying.record(entrant, graded.rows[i]) end
        state = nextState
        commitState(eventState, state)
        out.count, out.changed = out.count + #pending, true
      end
    end
    -- Mark the existing compressed plan complete only when every entrant's
    -- current attempt exists. Do not call completeRound: it may exceed the budget.
    local roundComplete = true
    for _, entrant in ipairs(eventState.entrants or {}) do
      if not qualifying.isDone(entrant) and qualifying.attemptCount(entrant) < info.number then roundComplete = false end
    end
    if roundComplete and plan and not plan.complete then
      plan.complete = true
      out.changed = true
    end
    out.complete = roundComplete
    return out
  end

  if eventState.phase ~= 'eliminations' or not eventState.bracket then return out end
  local round = eventState.bracket.rounds and eventState.bracket.rounds[eventState.bracket.currentRound]
  if not round then out.error = 'The current elimination round is unavailable.'; return out end
  for _, match in ipairs(round.matches or {}) do
    if out.count >= limit then break end
    if not match.winnerId and not match.complete then
      local a, b = byId[tostring(match.a)], byId[tostring(match.b)]
      if not a or not b then out.error = 'An elimination entrant is unavailable.'; return out end
      if not a.player and not b.player then
        local ra, nextState = makeRow(a, state)
        local rb; rb, nextState = makeRow(b, nextState)
        local pass, err = classes.applyResult(key, {rows = {ra, rb}}, 'eliminations', eventState)
        if not pass then out.error = err or 'Background elimination grading failed.'; return out end
        local recorded, reason = bracket.record(match, pass)
        if not recorded then out.error = reason; return out end
        match.simulated = true
        state = nextState
        commitState(eventState, state)
        out.count, out.changed = out.count + 1, true
      end
    end
  end
  out.complete = true
  for _, match in ipairs(round.matches or {}) do if not match.winnerId and not match.complete then out.complete = false end end
  return out
end

return M
