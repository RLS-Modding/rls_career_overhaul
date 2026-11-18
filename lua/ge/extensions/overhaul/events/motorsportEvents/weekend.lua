-- Owns multi-entry class activation and result snapshots.
-- registration.lua creates entries; weekendProgress.lua selects the next session; the coordinator runs it.
local M = {}
local definitions = require('overhaul/events/motorsportEvents/definitions')
local catalog = require('overhaul/events/motorsportEvents/drag/catalog')
local classes = require('overhaul/events/motorsportEvents/drag/classes')
local qualifying = require('overhaul/events/motorsportEvents/drag/qualifying')
local rewards = require('overhaul/events/motorsportEvents/rewards')

local function copy(value)
  if type(value) ~= 'table' then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

local registrationId = require('overhaul/events/motorsportEvents/classFields').registrationId

local function activeRegistration(eventState)
  for _, row in ipairs(eventState.registrations or {}) do
    if registrationId(row) == eventState.activeRegistrationId then return row end
  end
end

local function activeClass(eventState)
  for _, session in ipairs(eventState.classes or {}) do
    if session.id == eventState.activeClassId then return session end
  end
end

local function registrationClass(eventState, row)
  if not row.classId then return end
  for _, session in ipairs(eventState.classes or {}) do
    if session.classId == row.classId then return session end
  end
end

local function orderedClasses(eventState)
  local result, seen = {}, {}
  for _, row in ipairs(eventState.registrations or {}) do
    local session = registrationClass(eventState, row)
    if session and not seen[session.id] then
      seen[session.id] = true
      if not row.excluded then result[#result + 1] = session end
    end
  end
  for _, session in ipairs(eventState.classes or {}) do
    if not seen[session.id] then result[#result + 1] = session end
  end
  return result
end

local function playerEntrant(row)
  local entrant = {}
  for key, value in pairs(row) do if key ~= 'qualifyingOpponents' then entrant[key] = copy(value) end end
  entrant.qualifyingOpponents, entrant.qualifyingRosterClassId, entrant.qualifyingRosterError = nil, nil, nil
  entrant.player, entrant.name = true, row.name or 'You'
  entrant.number = row.number or 0
  entrant.dial = row.qualifying and row.qualifying.valid and row.qualifying.time or row.dial or 10
  return entrant
end

local function reconcileOpponents(eventState, row, entrants)
  if not eventState or eventState.phase ~= 'playerQualifying' or eventState.activeClassId or eventState.activeRegistrationId ~= registrationId(row) then return end
  local active, matchingPlayer = {}, false
  for _, entrant in ipairs(eventState.entrants or {}) do
    if entrant.player then
      matchingPlayer = registrationId(entrant) == registrationId(row) and entrant.declaredClassId == row.declaredClassId
    else active[entrant.id] = entrant end
  end
  if not matchingPlayer then return end
  for i, frozen in ipairs(entrants) do
    local live = active[frozen.id]
    if live and live ~= frozen and live.model == frozen.model and live.config == frozen.config then
      if qualifying.attemptCount(frozen) > qualifying.attemptCount(live) then
        live.qualifying, live.qualifyingAttempts, live.qualifierDone =
          copy(frozen.qualifying), copy(frozen.qualifyingAttempts), frozen.qualifierDone
      end
      live.qualifyingLimit = frozen.qualifyingLimit or definitions.event(eventState).qualifyingAttempts
      entrants[i] = live
    end
  end
end

local function opponents(row, eventState)
  if row.qualifyingRosterClassId and row.qualifyingRosterClassId ~= row.declaredClassId then
    return nil, 'The declared class changed after its qualifying field was frozen.'
  end
  local entrants = row.qualifyingOpponents
  if not entrants then
    local drivers = catalog.drivers(row.declaredClassId, eventState)
    local count = definitions.event(eventState).opponentCount
    if #drivers < count then return nil, 'The selected class needs at least ' .. count .. ' available opponents.' end
    entrants = {}
    local people = {}
    for _, driver in ipairs(drivers) do
      if #entrants >= count then break end
      local person = catalog.opponentIdentity(driver, catalog.getClass(row.declaredClassId, eventState))
      if not people[person] then
        people[person] = true
        local entrant = copy(driver)
        entrant.classId, entrant.leagueId = row.declaredClassId, row.leagueId
        entrant.name, entrant.number = driver.driverName or driver.name or driver.id, driver.driverNumber or driver.number
        entrant.player, entrant.qualifying, entrant.seed, entrant.qualifyingAttempts, entrant.qualifierDone = false, nil, nil, nil, false
        entrant.qualifyingLimit, entrant.dial = row.qualifyingLimit or definitions.event(eventState).qualifyingAttempts, tonumber(driver.estimatedET) or row.dial or 10
        entrants[#entrants + 1] = entrant
      end
    end
    if #entrants < count then return nil, "The class needs more distinct drivers." end
  end
  local expected = row.qualifyingRosterCount or definitions.event(eventState).opponentCount
  if #entrants ~= expected then return nil, 'The selected class needs its complete ' .. expected .. '-driver roster.' end
  row.qualifyingRosterCount = expected
  local ids = {}
  for _, entrant in ipairs(entrants) do
    if not entrant.id or not entrant.model or not entrant.config or ids[entrant.id] then
      return nil, 'An opponent configuration is unavailable.'
    end
    ids[entrant.id] = true
    entrant.qualifyingLimit = entrant.qualifyingLimit or row.qualifyingLimit or definitions.event(eventState).qualifyingAttempts
  end
  reconcileOpponents(eventState, row, entrants)
  row.qualifyingOpponents, row.qualifyingRosterClassId, row.qualifyingRosterError = entrants, row.declaredClassId, nil
  return entrants
end

local function preparePlayer(eventState, row)
  row.registrationId = registrationId(row)
  row.qualifyingLimit = row.qualifyingLimit or definitions.event(eventState).qualifyingAttempts
  local field, err = opponents(row, eventState)
  row.qualifyingRosterError = err
  local entrants = {playerEntrant(row)}
  entrants[1].qualifyingPassAttempt = qualifying.attemptCount(row)
  if field then
    for _, opponent in ipairs(field) do entrants[#entrants + 1] = opponent end
  end
  eventState.activeRegistrationId, eventState.activeClassId = row.registrationId, nil
  eventState.phase, eventState.className, eventState.entrants, eventState.bracket = 'playerQualifying', row.declaredClassName or 'Player qualifying', entrants, nil
  eventState.winnerId, eventState.reward, eventState.rewardPaid = nil, nil, false
  eventState.placings, eventState.playerPlace = nil, nil
  return {ok = true, phase = eventState.phase, player = row}
end

local function exclude(row, reason)
  row.excluded, row.classError, row.error = true, reason, reason
  return {ok = false, excluded = row, error = reason}
end

function M.nextPlayer(eventState)
  for _, row in ipairs(eventState and eventState.registrations or {}) do
    if not row.excluded and not row.classId then return row end
  end
end

function M.beginQualifying(eventState)
  if not eventState or eventState.formatVersion ~= 2 or eventState.phase ~= 'registration' then return {ok = false, error = 'Registration is closed.'} end
  if not eventState.registrationPaid or #(eventState.registrations or {}) == 0 then return {ok = false, error = 'Register and pay for your entries first.'} end
  eventState.classes = eventState.classes or {}
  return M.prepareNext(eventState)
end

function M.recordPlayer(eventState, result)
  if not eventState or eventState.formatVersion ~= 2 or eventState.phase ~= 'playerQualifying' then return {ok = false, error = 'No player qualifying pass is active.'} end
  local row = activeRegistration(eventState)
  if not row or row.excluded or row.classId then return {ok = false, error = 'This entry has already completed qualifying.'} end
  if result and result.entrantId and result.entrantId ~= row.id then return {ok = false, retry = true, error = 'The qualifying result belongs to another entry.'} end
  if result and result.simulated then return {ok = false, retry = true, error = 'Your class requires a real qualifying pass.'} end
  result = result or {}
  local time = tonumber(result.time)
  local assigned, err = classes.canEnter(row.leagueId, row.declaredClassId, row.traits, eventState)
  if not assigned then return exclude(row, err or 'This entry cannot run in its declared class.') end
  local field, fieldError = opponents(row, eventState)
  if not field then return exclude(row, fieldError) end
  local valid = time and time > 0 and time == time and time ~= math.huge and result.valid == true
  local reason = result.reason
  if valid then
    local allowed, validationError, reasonCode = classes.validate(row.declaredClassId, time, row.traits, eventState)
    if not allowed and reasonCode ~= 'breakout' then return exclude(row, validationError or 'This entry cannot run in its declared class.') end
    valid, reason = allowed ~= nil, validationError
  end
  reason = not valid and (reason or 'No valid elapsed time') or nil
  row.qualifyingLimit = row.qualifyingLimit or definitions.event(eventState).qualifyingAttempts
  local attempt = copy(result)
  attempt.valid, attempt.time, attempt.reason = valid == true, time, reason
  qualifying.record(row, attempt)
  if not qualifying.isDone(row) then
    preparePlayer(eventState, row)
    local progress = string.format('Qualifying attempt %d of %d recorded.', qualifying.attemptCount(row), qualifying.limit(row))
    return {ok = valid == true, retry = true, error = reason and reason .. ' ' .. progress or nil, message = valid and progress or nil}
  end
  row.dnq = not row.qualifying or row.qualifying.valid ~= true
  for _, session in ipairs(eventState.classes or {}) do
    if session.classId == assigned.id then return exclude(row, 'Only one vehicle per entrant per class') end
  end
  local entrants = {}
  for _, entrant in ipairs(field) do entrants[#entrants + 1] = entrant end
  row.classId, row.className, row.classError, row.error = assigned.id, assigned.name, nil, nil
  entrants[#entrants + 1] = playerEntrant(row)
  local session = {id = assigned.id, classId = assigned.id, name = assigned.name, className = assigned.name,
    leagueId = row.leagueId, phase = 'qualifying', entrants = entrants,
    prizes = rewards.prizes(eventState, row.leagueId), rewardPaid = false, playerInventoryId = row.inventoryId}
  eventState.classes = eventState.classes or {}
  eventState.classes[#eventState.classes + 1] = session
  return {ok = true, qualified = row, class = session, dnq = row.dnq,
    message = row.dnq and ('Your entry did not qualify after ' .. row.qualifyingLimit .. ' attempts. The declared class will continue.')
      or string.format('Qualifying complete. Best legal time: %.3f s.', row.qualifying.time)}
end

function M.recordPaired(eventState, result, passEntrants)
  if not eventState or eventState.formatVersion ~= 2 or eventState.phase ~= 'playerQualifying' then
    return {ok = false, error = 'No player qualifying pass is active.'}
  end
  local registration = activeRegistration(eventState)
  if not registration or registration.excluded or registration.classId then
    return {ok = false, error = 'This entry has already completed qualifying.'}
  end
  result = result or {}
  if result.error then return {ok = false, retry = true, error = result.error} end
  local pair, playerSnapshot, partnerId = passEntrants or qualifying.nextPair(eventState.entrants or {}) or {}
  for _, entrant in ipairs(pair) do
    if entrant.player then playerSnapshot = entrant else partnerId = entrant.id end
  end
  if not playerSnapshot or playerSnapshot.id ~= registration.id or registrationId(playerSnapshot) ~= registrationId(registration)
      or (playerSnapshot.qualifyingPassAttempt or qualifying.attemptCount(playerSnapshot)) ~= qualifying.attemptCount(registration) then
    return {ok = false, retry = true, error = 'This qualifying pass has already been recorded or belongs to another entry.'}
  end
  local playerResult, partnerResult
  for _, row in ipairs(result.rows or {}) do
    if row.entrantId == registration.id then playerResult = row
    elseif row.entrantId == partnerId then partnerResult = row end
  end
  if result.simulated or playerResult and playerResult.simulated or partnerResult and partnerResult.simulated then
    return {ok = false, retry = true, error = 'Your class requires a real qualifying pass.'}
  end
  local checked, err = classes.applyResult(registration.declaredClassId, {rows = partnerResult and {partnerResult} or {}}, 'qualifying', eventState)
  if not checked then return exclude(registration, err or 'The selected drag class is unavailable.') end
  local field, fieldError = opponents(registration, eventState)
  if not field then return exclude(registration, fieldError) end
  local opponent, recorded
  partnerResult = nil
  for _, row in ipairs(checked.rows or {}) do
    if row.entrantId == partnerId then partnerResult = row end
  end
  for _, entrant in ipairs(field) do
    if entrant.id == partnerId then
      opponent, recorded = entrant, qualifying.record(entrant, partnerResult or {valid = false, reason = 'No qualifying result'})
      break
    end
  end
  local outcome = M.recordPlayer(eventState, playerResult or {valid = false, reason = 'No qualifying result'})
  playerSnapshot.qualifying, playerSnapshot.qualifyingAttempts, playerSnapshot.qualifierDone =
    copy(registration.qualifying), copy(registration.qualifyingAttempts), registration.qualifierDone
  outcome.opponent, outcome.opponentRecorded = opponent, recorded == true
  return outcome
end

function M.gradeNpcQualifying(eventState, result)
  if not eventState or eventState.formatVersion ~= 2 or eventState.phase ~= 'playerQualifying' then return nil, 'No player qualifying field is active.' end
  local row = activeRegistration(eventState)
  if not row or row.excluded then return nil, 'This entry has already completed qualifying.' end
  if type(result) ~= 'table' then return nil, 'The qualifying result is unavailable.' end
  for _, resultRow in ipairs(type(result.rows) == 'table' and result.rows or {}) do
    if resultRow.entrantId == row.id then return nil, 'The player qualifying pass must be recorded with its paired result.' end
  end
  local field, err = opponents(row, eventState)
  if not field then return nil, err end
  return classes.applyResult(row.declaredClassId, result, 'qualifying', eventState)
end

function M.activate(eventState, session)
  if not eventState or eventState.formatVersion ~= 2 then return {ok = false, error = 'This event does not use weekend registration.'} end
  eventState.activeClassId, eventState.activeRegistrationId = session.id, nil
  eventState.phase, eventState.className, eventState.entrants, eventState.bracket = session.phase, session.name, session.entrants, session.bracket
  eventState.prizes, eventState.winnerId, eventState.rewardPaid, eventState.reward = session.prizes, session.winnerId, session.rewardPaid == true, session.reward
  eventState.placings, eventState.playerPlace = session.placings, session.playerPlace
  return {ok = true, phase = eventState.phase, class = session}
end

local function stageWaiting()
  return {ok = true, stageComplete = true, waiting = true}
end

function M.championshipFieldSize(eventState, session)
  session = session or activeClass(eventState)
  local size = session and session.championshipFieldSize or eventState.championshipFieldSize
  return size or definitions.event(eventState).finalsFieldSize
end

local function openingHeats(session, cutoff)
  local bracket = session.bracket
  local first = bracket and bracket.rounds and bracket.rounds[1]
  if not first or session.phase == 'complete' or bracket.winnerId or bracket.complete then return 0 end
  local matches, number, total = #first.matches, 1, 0
  while matches * 2 > cutoff do
    local round = bracket.rounds[number]
    if round then
      for _, match in ipairs(round.matches) do
        if match.a and match.b and not match.winnerId and not match.complete then total = total + 1 end
      end
    else total = total + matches end
    matches, number = math.floor(matches / 2), number + 1
  end
  return total
end

local function planChampionship(eventState, sessions)
  if eventState.championshipPlanned then return end
  local definition = definitions.event(eventState)
  local cutoff = definition.finalsFieldSize
  eventState.championshipFieldSize = cutoff
  local total = 0
  for _, session in ipairs(sessions) do
    session.championshipFieldSize = nil
    total = total + openingHeats(session, cutoff)
  end
  for _, session in ipairs(sessions) do
    if total <= definition.earlyHeatBudget then break end
    local moved = openingHeats(session, cutoff) - openingHeats(session, cutoff * 2)
    if moved > 0 then session.championshipFieldSize, total = cutoff * 2, total - moved end
  end
  eventState.championshipPlanned = true
end

local function nextQualifying(eventState)
  local selected, selectedSession, round, seen = nil, nil, nil, {}
  for _, row in ipairs(eventState.registrations or {}) do
    local session = registrationClass(eventState, row)
    if session then seen[session.id] = true end
    if not row.excluded and (not session or session.phase == 'qualifying') then
      local field = session and session.entrants
      if not field then
        field = {row}
        for _, entrant in ipairs(row.qualifyingOpponents or {}) do field[#field + 1] = entrant end
      end
      local info = qualifying.roundInfo(field)
      if not info.complete and (not round or info.number < round) then
        selected, selectedSession, round = row, session, info.number
      end
    end
  end
  for _, session in ipairs(eventState.classes or {}) do
    if not seen[session.id] and session.phase == 'qualifying' then
      local info = qualifying.roundInfo(session.entrants)
      if not info.complete and (not round or info.number < round) then
        selected, selectedSession, round = nil, session, info.number
      end
    end
  end
  if not selected and not selectedSession then return stageWaiting() end
  local result = selectedSession and M.activate(eventState, selectedSession) or preparePlayer(eventState, selected)
  result.round = round
  return result
end

local function nextElimination(eventState, stage)
  local bracket = require('overhaul/events/motorsportEvents/drag/bracket')
  local selected, round
  for _, session in ipairs(orderedClasses(eventState)) do
    if session.phase ~= 'complete' then
      if not session.bracket then return {ok = false, blocked = true, waiting = true, error = 'Seed every class bracket before eliminations.'} end
      local match = bracket.nextMatch(session.bracket)
      local current = session.bracket.rounds[session.bracket.currentRound]
      local opening = match and current and #current.matches * 2 > M.championshipFieldSize(eventState, session)
      if stage == 'finals' and opening then
        return {ok = false, blocked = true, waiting = true, error = 'Complete every class opening elimination round before championship day.'}
      end
      local eligible = stage == 'eliminations' and opening or stage == 'finals' and not opening
      if eligible and (not round or session.bracket.currentRound < round) then
        selected, round = session, session.bracket.currentRound
      end
    end
  end
  if not selected then return stageWaiting() end
  local result = M.activate(eventState, selected)
  result.round = round
  return result
end

function M.prepareNext(eventState, options)
  if not eventState or eventState.formatVersion ~= 2 then return {ok = false, error = 'This event does not use weekend registration.'} end
  if eventState.pendingRefund then return {ok = false, error = 'Waiting for the entry fee refund.'} end
  if options and options.rotate == true then
    M.sync(eventState)
    if options.stage == 'qualifying' then return nextQualifying(eventState) end
    if options.stage == 'eliminations' or options.stage == 'finals' then return nextElimination(eventState, options.stage) end
    return {ok = false, error = 'This weekend stage is unavailable.'}
  end
  local current = activeClass(eventState)
  local row = activeRegistration(eventState)
  if not current and row and row.classId then
    for _, session in ipairs(eventState.classes or {}) do if session.classId == row.classId then current = session; break end end
  end
  if current and current.phase == 'qualifying' and qualifying.nextEntrant(current.entrants) then return M.activate(eventState, current) end
  local pending = M.nextPlayer(eventState)
  if pending then return preparePlayer(eventState, pending) end
  for _, session in ipairs(eventState.classes or {}) do
    if session.phase ~= 'complete' then return M.activate(eventState, session) end
  end
  if #(eventState.classes or {}) > 0 then eventState.phase = 'complete'; return {ok = true, phase = eventState.phase} end
  eventState.registrationFailures = eventState.registrationFailures or {}
  for _, row in ipairs(eventState.registrations or {}) do eventState.registrationFailures[#eventState.registrationFailures + 1] = copy(row) end
  eventState.phase, eventState.registrations, eventState.registrationPaid, eventState.registrationFee = 'registration', {}, false, 0
  eventState.activeRegistrationId, eventState.activeClassId, eventState.entrants, eventState.bracket, eventState.className = nil, nil, {}, nil, 'Registration'
  return {ok = true, phase = eventState.phase, reopened = true}
end

function M.sync(eventState)
  if not eventState or eventState.formatVersion ~= 2 then return end
  local session = activeClass(eventState)
  if not session then
    local row = activeRegistration(eventState)
    if row and eventState.phase == 'playerQualifying' then opponents(row, eventState) end
    return
  end
  session.phase, session.entrants, session.bracket = eventState.phase, eventState.entrants, eventState.bracket
  session.winnerId, session.rewardPaid, session.reward = eventState.winnerId, eventState.rewardPaid, eventState.reward
  session.prizes, session.placings, session.playerPlace = eventState.prizes, eventState.placings, eventState.playerPlace
end

function M.seedBrackets(eventState)
  if not eventState or eventState.formatVersion ~= 2 then return {ok = false, error = 'This event does not use weekend registration.'} end
  if eventState.pendingRefund then return {ok = false, error = 'Waiting for the entry fee refund.'} end
  M.sync(eventState)
  for _, row in ipairs(eventState.registrations or {}) do
    if not row.excluded and not registrationClass(eventState, row) then return {ok = false, error = 'Finish qualifying every entered class first.'} end
  end
  local sessions = orderedClasses(eventState)
  for _, session in ipairs(sessions) do
    if qualifying.nextEntrant(session.entrants or {}) then return {ok = false, error = 'Finish qualifying every entered class first.'} end
  end
  if #sessions == 0 then return stageWaiting() end
  local bracket, seeded = require('overhaul/events/motorsportEvents/drag/bracket'), 0
  for _, session in ipairs(sessions) do
    if not session.bracket then
      local built = bracket.build(qualifying.standings(session.entrants), definitions.qualifyingFieldSize(eventState))
      if not built then
        built = {rounds = {}, currentRound = 1, complete = true, noQualified = true}
        session.reward, session.rewardPaid = 0, true
      end
      session.bracket, seeded = built, seeded + 1
    end
    if session.phase ~= 'complete' then session.phase = 'eliminations' end
  end
  planChampionship(eventState, sessions)
  local current = activeClass(eventState)
  if not current or current.phase == 'complete' then
    for _, session in ipairs(sessions) do if session.phase ~= 'complete' then current = session; break end end
  end
  if current then M.activate(eventState, current) end
  return {ok = true, phase = eventState.phase, seeded = seeded, classes = #sessions}
end

function M.finishClass(eventState)
  if not eventState or eventState.formatVersion ~= 2 then return eventState and eventState.phase == 'complete' or false end
  M.sync(eventState)
  local session = activeClass(eventState)
  if session then session.phase = 'complete' end
  for _, nextSession in ipairs(eventState.classes or {}) do
    if nextSession.phase ~= 'complete' then M.activate(eventState, nextSession); return false end
  end
  eventState.phase = 'complete'
  return true
end

function M.resume(eventState)
  if not eventState or eventState.formatVersion ~= 2 then return eventState end
  if catalog.refreshNames then catalog.refreshNames(eventState) end
  if eventState.pendingRefund then return eventState end
  if eventState.phase == 'complete' then
    local session = activeClass(eventState)
    if session then eventState.entrants, eventState.bracket, eventState.prizes = session.entrants, session.bracket, session.prizes end
    if session then eventState.placings, eventState.playerPlace = session.placings, session.playerPlace end
  elseif eventState.phase == 'playerQualifying' then
    local pending = activeRegistration(eventState) or M.nextPlayer(eventState)
    if pending and not pending.excluded and not pending.classId then preparePlayer(eventState, pending)
    else M.prepareNext(eventState) end
  elseif eventState.activeClassId then
    local session = activeClass(eventState)
    if session then M.activate(eventState, session) end
  end
  return eventState
end

return M
