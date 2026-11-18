-- Owns physical NPC qualifying views for spectators.
-- drag/qualifyingSchedule.lua supplies attempts; the coordinator switches views and records results into the event.
local M = {}
local definitions = require('overhaul/events/motorsportEvents/definitions')
local qualifying = require('overhaul/events/motorsportEvents/drag/qualifying')
local classes = require('overhaul/events/motorsportEvents/drag/classes')
local bracket = require('overhaul/events/motorsportEvents/drag/bracket')
local weekend = require('overhaul/events/motorsportEvents/weekend')
local views = setmetatable({}, {__mode = 'k'})

local classFields = require('overhaul/events/motorsportEvents/classFields')
local registrationId, fields = classFields.registrationId, classFields.fields

local function fieldById(eventState, id)
  for _, field in ipairs(fields(eventState)) do if field.id == id then return field end end
end

local function locked(eventState, field)
  local session = field.session
  if not session then return false end
  if session.phase == 'complete' or session.qualifyingLocked or session.rewardPaid and not (session.bracket and session.bracket.noQualified) then return true end
  if eventState.phase == 'eliminations' and eventState.activeClassId == session.id and eventState.inFlight then return true end
  for _, round in ipairs(session.bracket and session.bracket.rounds or {}) do
    for _, match in ipairs(round.matches or {}) do
      if not match.bye and (match.results ~= nil or match.winnerId ~= nil) then return true end
    end
  end
  return false
end

local function partner(eventState, field, round)
  if not field.player or qualifying.attemptAt(field.player, round) then return nil end
  local class = eventState.qualifyingSchedule and eventState.qualifyingSchedule.classes and eventState.qualifyingSchedule.classes[field.id]
  local plan = class and class.rounds[tostring(round)]
  for _, heat in ipairs(plan and plan.heats or {}) do
    for index, id in ipairs(heat.ids or {}) do
      if id == field.player.id then return heat.ids[index == 1 and 2 or 1] end
    end
  end
  if round > 1 then
    local entrants = {field.player}
    for _, entrant in ipairs(field.opponents) do entrants[#entrants + 1] = entrant end
    local group = qualifying.physicalGroup(entrants, round) or {}
    for index, entrant in ipairs(group) do
      if entrant.player then
        local opponent = group[index % 2 == 1 and index + 1 or index - 1]
        return opponent and opponent.id
      end
    end
  end
  return field.opponents[1] and field.opponents[1].id
end

local function targets(eventState, field, round, missing)
  local selected, count, reserved = {}, 0, partner(eventState, field, round)
  for _, entrant in ipairs(field.opponents) do
    local attempt = qualifying.attemptAt(entrant, round)
    if entrant.id ~= reserved and (attempt and attempt.simulated == true
      or missing and not attempt and qualifying.attemptCount(entrant) == round - 1 and round <= qualifying.limit(entrant)) then
      selected[entrant.id], count = true, count + 1
    end
  end
  return selected, count
end

local function choose(eventState)
  local all, active = fields(eventState)
  for _, field in ipairs(all) do
    if eventState.activeClassId and eventState.activeClassId == (field.session and field.session.id)
      or field.registration and eventState.activeRegistrationId == registrationId(field.registration) then active = field; break end
  end
  if active and not locked(eventState, active) then
    local info = qualifying.roundInfo(active.all)
    if not info.complete then
      local selected = targets(eventState, active, info.number, true)
      for _, entrant in ipairs(active.opponents) do
        if selected[entrant.id] and not qualifying.attemptAt(entrant, info.number) then return active, info.number, selected end
      end
    end
  end
  local wasLocked = false
  for round = 1, 3 do
    for _, field in ipairs(all) do
      local selected, count = targets(eventState, field, round, false)
      if count > 0 then
        if locked(eventState, field) then wasLocked = true else return field, round, selected end
      end
    end
  end
  if wasLocked then return nil, nil, nil, 'Qualifying results are locked once elimination heats have begun.' end
end

local function state(eventState)
  if not eventState.spectatorQualifying then eventState.spectatorQualifying = {version = 1, nextJobId = 1, dirtyClasses = {}} end
  local value = eventState.spectatorQualifying
  if value.version ~= 1 or type(value.dirtyClasses) ~= 'table' or type(value.nextJobId) ~= 'number'
    or value.nextJobId < 1 or value.nextJobId ~= math.floor(value.nextJobId) then return nil, 'The saved spectator qualifying work is unavailable.' end
  return value
end

local function done(field, heat, round)
  local byId = {}
  for _, entrant in ipairs(field.opponents) do byId[entrant.id] = entrant end
  for _, id in ipairs(heat.ids) do
    local entrant = byId[id]
    local attempt = entrant and qualifying.attemptAt(entrant, round)
    if not attempt or attempt.simulated == true then return false end
  end
  return true
end

function M.context(eventState)
  local job = eventState and eventState.spectatorQualifying and eventState.spectatorQualifying.job
  if not job then return nil end
  local cached = views[eventState]
  if cached and cached.job == job and cached.heats == job.heats then return cached.view end
  local field = fieldById(eventState, job.classId)
  if not field then return nil, 'The spectator qualifying class is unavailable.' end
  local view, byId = {}, {}
  for key, value in pairs(eventState) do view[key] = value end
  for _, entrant in ipairs(field.opponents) do byId[entrant.id] = entrant end
  view.phase, view.qualifyingCompression, view.roundRotation, view.weekendStage = 'qualifying', false, true, 'qualifying'
  view.className = field.session and field.session.name or field.registration and field.registration.declaredClassName or field.id
  view.activeClassId, view.activeRegistrationId, view.bracket = job.classId, nil, nil
  view.entrants, view.spectatorHeats = field.opponents, {}
  view.spectatorQualifyingKey, view.spectatorRound = job.key, {number = job.round, maxRounds = 3}
  for _, saved in ipairs(job.heats) do
    local heat = {entrants = {}, attempts = {}, spectatorRound = job.round}
    for _, id in ipairs(saved.ids) do
      if not byId[id] then return nil, 'A spectator qualifying opponent is unavailable.' end
      heat.entrants[#heat.entrants + 1], heat.attempts[#heat.attempts + 1] = byId[id], job.round - 1
    end
    view.spectatorHeats[#view.spectatorHeats + 1] = heat
  end
  views[eventState] = {job = job, heats = job.heats, view = view}
  return view
end

function M.finished(eventState)
  local job = eventState and eventState.spectatorQualifying and eventState.spectatorQualifying.job
  if not job then return true end
  local field = fieldById(eventState, job.classId)
  if not field then return false end
  for _, heat in ipairs(job.heats) do if not done(field, heat, job.round) then return false end end
  return true
end

function M.start(eventState)
  if not eventState or eventState.formatVersion ~= 2 or eventState.phase == 'registration' or eventState.phase == 'complete' then return nil end
  if eventState.pendingRefund then return nil, 'Waiting for the entry fee refund.' end
  weekend.sync(eventState)
  local saved, err = state(eventState)
  if not saved then return nil, err end
  if saved.job then
    if not M.finished(eventState) then return M.context(eventState) end
    if saved.job.exiting then return nil end
    saved.job = nil
  end
  local field, round, selected, selectionError = choose(eventState)
  if not field then return nil, selectionError end
  local job = {classId = field.id, round = round, heats = {}, exiting = false,
    key = tostring(eventState.id) .. ':spectator:' .. tostring(saved.nextJobId) .. ':' .. field.id .. ':' .. round}
  saved.nextJobId = saved.nextJobId + 1
  local function add(a, b)
    local ids = {}
    if a and selected[a.id] then ids[#ids + 1] = a.id end
    if b and selected[b.id] then ids[#ids + 1] = b.id end
    if #ids > 0 then job.heats[#job.heats + 1] = {ids = ids} end
  end
  if round > 1 then
    local ordered = qualifying.orderForRound(field.opponents, round)
    for index = 1, #ordered, 2 do add(ordered[index], ordered[index + 1]) end
  else
    add(field.opponents[1])
    for index = 2, #field.opponents, 2 do add(field.opponents[index], field.opponents[index + 1]) end
  end
  saved.job = job
  return M.context(eventState)
end

function M.hasWork(eventState)
  if not eventState or eventState.formatVersion ~= 2 or eventState.phase == 'registration' or eventState.phase == 'complete' or eventState.pendingRefund then return false end
  if eventState.spectatorQualifying and eventState.spectatorQualifying.job and not M.finished(eventState) then return true end
  local field, _, _, err = choose(eventState)
  return field ~= nil, err
end

function M.exit(eventState, claimedHeats)
  local saved = eventState and eventState.spectatorQualifying
  if not saved or not saved.job then return nil end
  if saved.job.exiting then return M.context(eventState) end
  local job, claimed = saved.job, {}
  for _, heat in ipairs(claimedHeats or {}) do
    for _, id in ipairs(heat.ids or heat) do claimed[type(id) == 'table' and id.id or id] = true end
  end
  local field, retained = fieldById(eventState, job.classId), {}
  if not field then return nil, 'The spectator qualifying class is unavailable.' end
  for _, heat in ipairs(job.heats) do
    local keep = done(field, heat, job.round)
    for _, id in ipairs(heat.ids) do if claimed[id] then keep = true end end
    if keep then retained[#retained + 1] = heat end
  end
  job.heats, job.exiting = retained, true
  return M.context(eventState)
end

local function synchronize(eventState, field, entrant)
  local function replace(rows)
    for index, row in ipairs(rows or {}) do if row.id == entrant.id and not row.player then rows[index] = entrant end end
  end
  if field.registration then replace(field.registration.qualifyingOpponents) end
  if field.session then replace(field.session.entrants) end
  if eventState.activeClassId and eventState.activeClassId == (field.session and field.session.id)
    or field.registration and eventState.activeRegistrationId == registrationId(field.registration) then replace(eventState.entrants) end
end

function M.record(eventState, view, result)
  local saved = eventState and eventState.spectatorQualifying
  local job = saved and saved.job
  if not job or not view or view.id ~= eventState.id or view.spectatorQualifyingKey ~= job.key
    or view.spectatorQualifying ~= saved then return {ok = false, changed = false, error = 'This spectator qualifying pass is no longer active.'} end
  if not result or result.error or result.simulated then return {ok = false, changed = false, error = result and result.error or 'A physical qualifying result is required.'} end
  local field, allowed, byId = fieldById(eventState, job.classId), {}, {}
  if not field or locked(eventState, field) then return {ok = false, changed = false, error = 'Qualifying results are locked once elimination heats have begun.'} end
  for _, heat in ipairs(job.heats) do for _, id in ipairs(heat.ids) do allowed[id] = true end end
  for _, entrant in ipairs(field.opponents) do byId[entrant.id] = entrant end
  local seen = {}
  if type(result.rows) ~= 'table' or #result.rows == 0 then return {ok = false, changed = false, error = 'The physical qualifying result is unavailable.'} end
  for _, row in ipairs(result.rows) do
    if not allowed[row.entrantId] or not byId[row.entrantId] or row.simulated or seen[row.entrantId] then return {ok = false, changed = false, error = 'The result belongs to another qualifying pass.'} end
    seen[row.entrantId] = true
    local previous = qualifying.attemptAt(byId[row.entrantId], job.round)
    if not previous and qualifying.attemptCount(byId[row.entrantId]) ~= job.round - 1 then return {ok = false, changed = false, error = 'An earlier qualifying attempt is unfinished.'} end
  end
  local graded, err = classes.applyResult(job.classId, result, 'qualifying', eventState)
  if not graded then return {ok = false, changed = false, error = err or 'The qualifying class is unavailable.'} end
  local changed = false
  for _, row in ipairs(graded.rows or {}) do
    local entrant = byId[row.entrantId]
    local previous = qualifying.attemptAt(entrant, job.round)
    if not previous or previous.simulated == true then
      local ok, recordError = qualifying.recordAt(entrant, job.round, row)
      if not ok then return {ok = false, changed = changed, error = recordError} end
      changed = true
      synchronize(eventState, field, entrant)
      local class = eventState.qualifyingSchedule and eventState.qualifyingSchedule.classes and eventState.qualifyingSchedule.classes[job.classId]
      local plan = class and class.rounds[tostring(job.round)]
      for index = #(plan and plan.simulatedRows or {}), 1, -1 do
        if plan.simulatedRows[index].entrantId == entrant.id then table.remove(plan.simulatedRows, index) end
      end
    end
  end
  if changed then saved.dirtyClasses[job.classId] = true end
  return {ok = true, changed = changed}
end

function M.clear(eventState)
  if eventState then
    views[eventState] = nil
    if eventState.spectatorQualifying then eventState.spectatorQualifying.job = nil end
  end
end

function M.reseed(eventState)
  local saved = eventState and eventState.spectatorQualifying
  if not saved then return {ok = true, changed = false} end
  if not M.finished(eventState) then return {ok = false, changed = false, error = 'Finish the claimed qualifying group before reseeding.'} end
  local pending = {}
  for _, field in ipairs(fields(eventState)) do
    if saved.dirtyClasses[field.id] then
      if locked(eventState, field) then return {ok = false, changed = false, error = 'An elimination bracket already in use cannot be reseeded.'} end
      pending[#pending + 1] = field
    end
  end
  local changed = false
  for _, field in ipairs(pending) do
    local session = field.session
    if session and session.bracket then
      local wasEmpty = session.bracket.noQualified
      local built = bracket.build(qualifying.standings(session.entrants), definitions.qualifyingFieldSize(eventState))
      if not built then
        built = {rounds = {}, currentRound = 1, complete = true, noQualified = true}
        session.reward, session.rewardPaid = 0, true
      elseif wasEmpty then session.reward, session.rewardPaid = nil, false end
      session.bracket, session.winnerId = built, nil
      if eventState.activeClassId == session.id then
        eventState.bracket, eventState.winnerId, eventState.reward, eventState.rewardPaid = built, nil, session.reward, session.rewardPaid == true
      end
      changed = true
    end
    saved.dirtyClasses[field.id] = nil
  end
  return {ok = true, changed = changed}
end

return M
