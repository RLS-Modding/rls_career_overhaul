-- Owns per-class qualifying heat schedules and bounded completion.
-- drag/qualifying.lua owns attempts; drag/classes.lua grades results; callers retain the schedule on event state.
local M = {}
local qualifying = require('overhaul/events/motorsportEvents/drag/qualifying')
local classes = require('overhaul/events/motorsportEvents/drag/classes')
local MODULUS = 2147483647

local function finite(value, allowZero)
  local number = tonumber(value)
  if number and number == number and number < math.huge and (allowZero and number >= 0 or number > 0) then return number end
end

local function classId(eventState)
  if eventState.activeClassId then return eventState.activeClassId end
  for _, row in ipairs(eventState.registrations or {}) do
    local id = row.registrationId or row.id
    if id == eventState.activeRegistrationId or row.id and row.leagueId and row.id .. ':' .. row.leagueId == eventState.activeRegistrationId then
      return row.declaredClassId
    end
  end
end

local function entrantsById(eventState)
  local result = {}
  for _, entrant in ipairs(eventState.entrants or {}) do result[tostring(entrant.id)] = entrant end
  return result
end

local function seed(eventState)
  local value = 1
  local name = tostring(eventState.id or '')
  for index = 1, #name do value = (value * 31 + name:byte(index)) % MODULUS end
  return value > 0 and value or 1
end

function M.enabled(eventState)
  return eventState ~= nil and eventState.qualifyingCompression == true and eventState.formatVersion == 2
    and (eventState.phase == 'playerQualifying' or eventState.phase == 'qualifying')
end

local function addProtected(plan, protectedHeats, byId)
  local additions, seen = {}, {}
  for _, heat in ipairs(plan.heats) do for _, id in ipairs(heat.ids) do seen[tostring(id)] = heat end end
  for _, ids in ipairs(protectedHeats or {}) do
    if #ids > 2 then return nil, 'A claimed qualifying heat has too many entrants.' end
    local existing, overlap
    for _, id in ipairs(ids) do
      if not byId[tostring(id)] then return nil, 'A claimed qualifying entrant is unavailable.' end
      local heat = seen[tostring(id)]
      if heat then
        if existing and existing ~= heat then return nil, 'Claimed qualifying pairings overlap different planned heats.' end
        existing, overlap = heat, true
      end
    end
    if #ids == 2 and tostring(ids[1]) == tostring(ids[2]) then return nil, 'A claimed qualifying heat repeats one entrant.' end
    if existing then
      if #ids == 2 then
        local a, b = tostring(ids[1]), tostring(ids[2])
        if #existing.ids ~= 2 or not (tostring(existing.ids[1]) == a and tostring(existing.ids[2]) == b
          or tostring(existing.ids[1]) == b and tostring(existing.ids[2]) == a) then
          return nil, 'A claimed qualifying pairing conflicts with its planned heat.'
        end
      end
    elseif #ids > 0 and not overlap then
      if plan.complete then return nil, 'A completed qualifying round cannot claim another physical heat.' end
      local heat = {ids = {}, attempts = {}, protected = true}
      for _, id in ipairs(ids) do
        heat.ids[#heat.ids + 1], heat.attempts[#heat.attempts + 1] = id, plan.round - 1
        seen[tostring(id)] = heat
      end
      additions[#additions + 1] = heat
    end
  end
  for _, heat in ipairs(additions) do plan.heats[#plan.heats + 1] = heat end
  return true
end

function M.prepare(eventState, round, protectedHeats)
  if not M.enabled(eventState) then return nil, 'Compressed qualifying is not active.' end
  local key = classId(eventState)
  if not key then return nil, 'The qualifying class is unavailable.' end
  round = round or qualifying.roundInfo(eventState.entrants).number
  local maximum = qualifying.roundInfo(eventState.entrants).maxRounds
  if not finite(round) or round ~= math.floor(round) or round > maximum then return nil, 'The qualifying round is unavailable.' end
  local state = eventState.qualifyingSchedule
  if not state then state = {version = 1, rngState = seed(eventState), classes = {}}; eventState.qualifyingSchedule = state end
  if state.version ~= 1 or type(state.classes) ~= 'table' then return nil, 'The saved qualifying schedule is unavailable.' end
  local class = state.classes[key]
  if not class then
    local player, opponents, ids = nil, {}, {}
    for _, entrant in ipairs(eventState.entrants or {}) do
      if entrant.player then
        if player then return nil, 'Only one player entry is allowed in each qualifying class.' end
        player = entrant.id
      else opponents[#opponents + 1] = entrant.id end
      ids[#ids + 1] = entrant.id
    end
    if not player then return nil, 'The registered qualifying entrant is unavailable.' end
    class = {physicalIds = {player}, entrantIds = ids, rounds = {}}
    for index = 1, math.min(5, #opponents) do class.physicalIds[#class.physicalIds + 1] = opponents[index] end
    state.classes[key] = class
  end
  local plan = class.rounds[tostring(round)]
  local currentRound = qualifying.roundInfo(eventState.entrants).number
  if plan and plan.provisional and round <= currentRound then plan = nil end
  if not plan then
    local physicalIds = class.physicalIds
    if round > 1 then
      local group = qualifying.physicalGroup(eventState.entrants, round)
      if not group then return nil, 'The registered qualifying entrant is unavailable.' end
      physicalIds = {}
      for _, entrant in ipairs(group) do physicalIds[#physicalIds + 1] = entrant.id end
    end
    plan = {round = round, classId = key, heats = {}, complete = false, simulatedRows = {}, provisional = round > currentRound}
    for index = 1, #physicalIds, 2 do
      local heat = {ids = {physicalIds[index], physicalIds[index + 1]}, attempts = {round - 1}}
      if heat.ids[2] then heat.attempts[2] = round - 1 end
      plan.heats[#plan.heats + 1] = heat
    end
    class.rounds[tostring(round)] = plan
  end
  local ok, err = addProtected(plan, protectedHeats, entrantsById(eventState))
  if not ok then return nil, err end
  return plan
end

function M.heats(eventState, round)
  local plan, err = M.prepare(eventState, round)
  if not plan then return nil, err end
  local byId, heats = entrantsById(eventState), {}
  for _, saved in ipairs(plan.heats) do
    local heat = {entrants = {}, attempts = {}, protected = saved.protected}
    for index, id in ipairs(saved.ids) do
      local entrant = byId[tostring(id)]
      if not entrant then return nil, 'A scheduled qualifying entrant is unavailable.' end
      heat.entrants[index], heat.attempts[index] = entrant, saved.attempts[index]
    end
    heats[#heats + 1] = heat
  end
  return heats, plan
end

function M.migrate(eventState)
  if not eventState or eventState.formatVersion ~= 2 or eventState.qualifyingCompression ~= nil then return {ok = true, migrated = false} end
  eventState.qualifyingCompression = true
  if not M.enabled(eventState) then return {ok = true, migrated = true} end
  local plan, err = M.prepare(eventState)
  if not plan then eventState.qualifyingCompression = nil; return {ok = false, migrated = false, error = err} end
  if not plan.complete then
    local class = eventState.qualifyingSchedule.classes[plan.classId]
    local ids = {class.physicalIds[1]}
    for _, id in ipairs(class.entrantIds) do if tostring(id) ~= tostring(ids[1]) then ids[#ids + 1] = id end end
    local heats = {}
    for index = 1, #ids, 2 do
      local heat = {ids = {ids[index], ids[index + 1]}, attempts = {plan.round - 1}, protected = true}
      if heat.ids[2] then heat.attempts[2] = plan.round - 1 end
      heats[#heats + 1] = heat
    end
    plan.heats, plan.legacyPhysical = heats, true
  end
  return {ok = true, migrated = true, preservedRound = plan.round}
end

local function baseline(entrant)
  local elapsed, reaction = finite(entrant.estimatedET), finite(entrant.estimatedReactionTime, true)
  local physical
  for _, result in ipairs(entrant.qualifyingAttempts or {}) do
    if result.valid == true and not result.simulated and not result.breakout and finite(result.time) then physical = result; break end
  end
  if not physical then
    local result = entrant.qualifying
    if result and result.valid == true and not result.simulated and not result.breakout and finite(result.time) then physical = result end
  end
  return elapsed or physical and finite(physical.time), reaction or physical and finite(physical.reaction, true)
end

function M.completeRound(eventState, options)
  if not M.enabled(eventState) then return {ok = false, error = 'Compressed qualifying is not active.', simulatedCount = 0} end
  local key = classId(eventState)
  local state, class = eventState.qualifyingSchedule
  class = state and key and state.classes and state.classes[key]
  if not class then
    local prepared, err = M.prepare(eventState)
    if not prepared then return {ok = false, error = err, simulatedCount = 0} end
    state, class = eventState.qualifyingSchedule, eventState.qualifyingSchedule.classes[key]
  end
  local plan, last
  for round = 1, qualifying.roundInfo(eventState.entrants).maxRounds do
    local saved = class.rounds[tostring(round)]
    if saved then last = saved; if not saved.complete then plan = saved; break end end
  end
  if not plan then return {ok = true, complete = last and last.complete == true, round = last and last.round, simulatedCount = 0, rows = {}} end
  local byId, physical = entrantsById(eventState), {}
  for _, heat in ipairs(plan.heats) do
    for _, id in ipairs(heat.ids) do
      local entrant = byId[tostring(id)]
      if not entrant then return {ok = false, error = 'A scheduled qualifying entrant is unavailable.', round = plan.round, simulatedCount = 0} end
      physical[tostring(id)] = true
      if qualifying.attemptCount(entrant) < plan.round and not qualifying.isDone(entrant) then
        return {ok = true, complete = false, round = plan.round, simulatedCount = 0, rows = {}}
      end
    end
  end
  if options and options.physicalOnly then
    for _, id in ipairs(class.entrantIds) do
      local entrant = byId[tostring(id)]
      if not entrant then return {ok = false, error = 'An event qualifying entrant is unavailable.', simulatedCount = 0} end
      if not qualifying.isDone(entrant) and qualifying.attemptCount(entrant) < plan.round then
        return {ok = true, complete = false, round = plan.round, simulatedCount = 0, rows = {}}
      end
    end
  end
  local rngState = finite(state.rngState)
  if not rngState or rngState >= MODULUS or rngState ~= math.floor(rngState) then
    return {ok = false, error = 'The saved qualifying random state is unavailable.', simulatedCount = 0}
  end
  local function draw()
    rngState = (rngState * 16807) % MODULUS
    return (rngState - 1) / (MODULUS - 1)
  end
  local rows = {}
  for _, id in ipairs(class.entrantIds) do
    local entrant = byId[tostring(id)]
    if not entrant then return {ok = false, error = 'An event qualifying entrant is unavailable.', simulatedCount = 0} end
    if not entrant.player and not physical[tostring(id)] and not qualifying.isDone(entrant) and qualifying.attemptCount(entrant) < plan.round then
      if qualifying.attemptCount(entrant) ~= plan.round - 1 then
        return {ok = false, error = 'An opponent has an unfinished earlier qualifying round.', simulatedCount = 0}
      end
      local elapsed, reaction = baseline(entrant)
      local etVariation, rtVariation = draw() - .5, draw() - .5
      local row = {entrantId = entrant.id, valid = elapsed ~= nil, simulated = true}
      if elapsed then row.time = elapsed + etVariation * math.min(.24, elapsed * .024)
      else row.reason = 'No measured elapsed-time baseline is available.' end
      if reaction then row.reaction = math.max(0, reaction + rtVariation * .03) end
      rows[#rows + 1] = row
    end
  end
  local graded, err = classes.applyResult(plan.classId, {rows = rows}, 'qualifying', eventState)
  if not graded then return {ok = false, error = err or 'Qualifying class grading failed.', simulatedCount = 0} end
  for _, row in ipairs(graded.rows) do qualifying.record(byId[tostring(row.entrantId)], row) end
  plan.simulatedRows, plan.complete, state.rngState = graded.rows, true, rngState
  return {ok = true, complete = true, round = plan.round, simulatedCount = #graded.rows, rows = graded.rows}
end

return M
