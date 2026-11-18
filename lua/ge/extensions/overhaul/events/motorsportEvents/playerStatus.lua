-- Owns the player's persistent outcome and next instruction. No UI or save writes.
-- Read order: vocabulary, entry outcomes, round context, instruction resolution.
local M = {}
local bracket = require('overhaul/events/motorsportEvents/drag/bracket')

M.labels = {finishEvent = 'Finish Event', startEvent = 'Start Event', final = 'Final',
  didNotQualify = 'Did not qualify', eliminated = 'Eliminated', excluded = 'Excluded',
  withdrawn = 'Withdrew', upcoming = 'Upcoming', racing = 'Racing', done = 'Done',
  simulated = 'Simulated', bye = 'Bye', noWinner = 'No winner'}

function M.count(value, total, label)
  return (label and label .. ' ' or '') .. tostring(value or 0) .. ' of ' .. tostring(total or 0)
end

function M.duration(value)
  local seconds = math.max(0, math.ceil(tonumber(value) or 0))
  if seconds < 60 then return seconds .. ' s' end
  return math.floor(seconds / 60) .. ' min' .. (seconds % 60 > 0 and ' ' .. seconds % 60 .. ' s' or '')
end

function M.roundName(round)
  if not round then return 'Eliminations' end
  if round.championship then return M.labels.final end
  local count = round.fullMatchCount or #(round.matches or {})
  return ({[1] = 'Final', [2] = 'Semifinals', [4] = 'Quarterfinals', [8] = 'Round of 16'})[count]
    or ('Round ' .. tostring(round.number or 1))
end

local function competition(eventState, entry)
  local classId = entry.declaredClassId or entry.classId
  if classId == eventState.activeClassId then return eventState end
  for _, class in ipairs(eventState.classes or {}) do
    if (class.id or class.classId) == classId then return class end
  end
  return eventState
end

local function entryOutcome(eventState, entry)
  local class = competition(eventState, entry)
  local result = {id = entry.registrationId or entry.id, entrantId = entry.id,
    classId = entry.declaredClassId or entry.classId,
    className = entry.declaredClassName or entry.className or class.name or class.className,
    carName = entry.vehicleName or entry.model, bestTime = entry.qualifying and entry.qualifying.valid and entry.qualifying.time,
    place = class.playerPlace, reward = class.reward or 0, role = 'entrant'}
  if entry.excluded then
    result.idOutcome, result.reason, result.role = 'excluded', entry.reason or entry.error or entry.classError, 'out'
    return result
  end
  local player = entry
  for _, entrant in ipairs(class.entrants or {}) do
    if entrant.id == entry.id then player = entrant; break end
  end
  result.bestTime = player.qualifying and player.qualifying.valid and player.qualifying.time or result.bestTime
  local outcome = class.bracket and bracket.playerOutcome(class.bracket, entry.id)
  if outcome == 'Eliminated' then result.idOutcome, result.role = 'eliminated', 'out'
  elseif outcome == 'Did not qualify' then result.idOutcome, result.role = 'didNotQualify', 'out'
  elseif outcome and outcome ~= 'Advancing' and outcome ~= 'Third-place race next' then
    result.idOutcome, result.role, result.label = 'placed', 'done', outcome
  elseif player.qualifierDone and not (player.qualifying and player.qualifying.valid) then
    result.idOutcome, result.role = 'didNotQualify', 'out'
  end
  local standings = {}
  for _, entrant in ipairs(class.entrants or {}) do
    if entrant.qualifying and entrant.qualifying.valid then standings[#standings + 1] = entrant.qualifying.time end
  end
  table.sort(standings)
  result.cutTime = standings[(eventState.eventDefinition or {}).qualifyingFieldSize or 16]
  for _, round in ipairs(class.bracket and class.bracket.rounds or {}) do
    for _, match in ipairs(round.matches or {}) do
      if (match.a == entry.id or match.b == entry.id) and match.winnerId and match.winnerId ~= entry.id then
        result.roundName, result.lostToId = M.roundName(round), match.winnerId
        for _, rival in ipairs(class.entrants or {}) do if rival.id == match.winnerId then result.lostTo = rival.name or rival.model end end
      end
    end
  end
  return result
end

function M.roundContext(eventState)
  if not eventState or not eventState.bracket then return nil, nil end
  local rounds = eventState.bracket.rounds or {}
  local current = eventState.bracket.currentRound or 1
  local round = rounds[current]
  local info = {name = M.roundName(round), number = current, of = #rounds}
  local names = {}
  for _, entrant in ipairs(eventState.entrants or {}) do names[entrant.id] = entrant.name or entrant.model end
  for _, match in ipairs(round and round.matches or {}) do
    if not match.complete and not match.winnerId then
      for _, entrant in ipairs(eventState.entrants or {}) do
        if entrant.player and (match.a == entrant.id or match.b == entrant.id) then
          return info, {names = {names[match.a] or 'To be decided', names[match.b] or 'To be decided'},
            entrantIds = {match.a, match.b}, lane = match.a == entrant.id and 'left' or 'right'}
        end
      end
    end
  end
  return info, nil
end

local holdKinds = {qualifying_schedule_pending = 'wait', group_pending = 'wait', spawn_pending = 'wait',
  player_qualifying_required = 'act', inspection_required = 'act', registered_car_required = 'act',
  group_parking_required = 'act', player_moving = 'act'}
function M.holdKind(code) return holdKinds[code] or 'blocked' end

local function step(id, title, text, tone, short, countdown)
  return {id = id, title = title, text = text or '', short = short or title, tone = tone or 'wait', countdown = countdown}
end

local outcomePriority = {placed = 4, eliminated = 3, excluded = 2, didNotQualify = 1}
local function summaryOutcome(entry)
  local summary = {}
  for key, value in pairs(entry) do summary[key] = value end
  summary.id = entry.idOutcome
  return summary
end

-- Finish Event has run: the result is acknowledged and the venue visit is closed.
-- Choosing to spectate also acknowledges the result, so the open visit keeps Finish Event available.
function M.finished(eventState, watching)
  return eventState ~= nil and eventState.phase == 'complete' and eventState.playerOutcomeAcknowledged == true
    and not watching and not eventState.checkIn and not eventState.venueArrivalDay and not eventState.venueSessionDay
end
function M.resolve(eventState, runtime, session, paddock, registration, checkIn, startBlocked, waitSeconds)
  if not eventState then return nil end
  runtime, session, paddock = runtime or {}, session or {}, paddock or {}
  registration, checkIn = registration or {}, checkIn or {}
  local result = {role = 'entrant', entries = {}}
  local allOut, outcome = true, nil
  local entries = eventState.registrations or {}
  -- Only legacy racing saves lack a registration roster. An empty roster
  -- is authoritative, including when an event is reopened for registration.
  if eventState.registrations == nil and eventState.phase ~= 'registration' then
    entries = {}
    for _, entrant in ipairs(eventState.entrants or {}) do if entrant.player then entries[#entries + 1] = entrant end end
  end
  for _, entry in ipairs(entries) do
    local status = entryOutcome(eventState, entry)
    result.entries[#result.entries + 1] = status
    if status.role == 'entrant' then allOut = false end
    if status.role ~= 'entrant' and (not outcome
      or (outcomePriority[status.idOutcome] or 0) > (outcomePriority[outcome.idOutcome] or 0)) then outcome = status end
  end
  -- Every class must be done with its player car, including restored fields
  -- whose registration is missing. The active class snapshot may lag a result.
  for _, class in ipairs(eventState.classes or {}) do
    if class.phase ~= 'complete' then
      local source = (class.id or class.classId) == eventState.activeClassId and eventState or class
      for _, entrant in ipairs(class.entrants or {}) do
        if entrant.player and entryOutcome(source, entrant).role == 'entrant' then allOut = false end
      end
    end
  end
  local out = allOut and (#entries > 0 or session.spectatorOnly or eventState.playerEliminated == true)
  local finishReason
  if runtime.pendingBet then finishReason = 'Wait for your bet to settle before choosing Finish Event.'
  elseif eventState.pendingRefund then finishReason = 'Wait for your entry fee refund before choosing Finish Event.'
  elseif eventState.withdrawn then finishReason = 'This entry has been withdrawn.'
  elseif M.finished(eventState, runtime.watching) then finishReason = "You've finished this event."
  elseif eventState.phase ~= 'complete' and (eventState.phase == 'registration' or not out) then
    finishReason = 'An entered car can still compete.'
  end
  result.finishEvent = {allowed = finishReason == nil, reason = finishReason}
  result.round, result.nextPairing = M.roundContext(eventState)
  if eventState.withdrawn then
    result.role, result.outcome = 'withdrawn', {id = 'withdrawn', reward = eventState.reward or 0}
    result.step = step('withdrawn', 'You withdrew', 'Payouts already earned are kept. Entry fees are not refunded.', 'blocked')
  elseif eventState.phase == 'complete' then
    result.role, result.outcome = 'done', summaryOutcome(outcome or {idOutcome = 'placed', reward = eventState.reward or 0})
    result.step = step('complete', 'Event complete', finishReason or '', 'done')
  elseif out then
    outcome = summaryOutcome(outcome or {idOutcome = eventState.playerEliminated and 'eliminated' or 'didNotQualify'})
    result.role, result.outcome = 'out', outcome
    local id = outcome.idOutcome
    local title = id == 'excluded' and 'Entry excluded' or id == 'eliminated'
      and (outcome.roundName and "You're out in the " .. outcome.roundName:lower() or 'You have been eliminated')
      or id == 'placed' and 'Your racing is finished' or 'You did not qualify'
    -- Some reasons arrive as whole sentences; the join adds the one full stop.
    local reason = outcome.reason and outcome.reason:gsub('%.$', '') .. '. ' or ''
    -- Every surface that can finish the event shows its own Finish Event button, so the text does not name it.
    local text = reason .. (finishReason or 'Watch from the stands.')
    result.step = id == 'placed' and step('racingFinished', title, text, 'done', (outcome.label or 'Racing finished') .. '. Watching')
      or step(id == 'excluded' and 'outExcluded' or id == 'eliminated' and 'outEliminated' or 'outDidNotQualify', title, text, 'blocked', (M.labels[id] or 'Racing finished') .. '. Watching')
    -- Already in the stands, so only the way out is left to say.
    if runtime.watching then
      result.step = step('spectating', 'Spectating', (title .. '. ' .. reason .. (finishReason or '')):gsub('%s+$', ''), 'wait',
        'Watching ' .. (result.round and result.round.name:lower() or 'the event'))
    end
  elseif eventState.phase == 'registration' then
    result.step = #entries > 0 and step('registrationReady', 'Entries registered', 'Bring more cars to registration, or choose Start Event when ready.', 'act')
      or registration.atRegistration and step('registrationChoose', 'Choose your entries', 'Pick classes at the desk, then pay the entry fees.', 'act')
      or step('registrationRoute', 'Head to registration', 'Bring your race cars. Pick classes and pay at the desk.', 'act', 'Registration open. Follow the route')
  elseif session.checkInRequired and (session.inspectionAvailable ~= false or not session.waiting) then
    result.step = checkIn.atCheckIn and step('checkInInspect', 'Inspect your cars', 'Use the check-in window.', 'act')
      or step('checkInRoute', 'Daily inspection', 'Bring your registered cars to check-in.', 'act', 'Bring your cars to check-in')
  elseif session.waiting then
    local title = (session.nextLabel or 'Next session') .. (session.nextDay and ' on Day ' .. session.nextDay or '')
    result.step = session.clockReady == false and step('scheduleUnavailable', 'Schedule unavailable', 'Check-in opens once the career calendar is ready.')
      or step('waitForSession', title, session.realTime and 'Real time, even while paused. Your entry is held.' or 'Your entry is held. Arriving late is fine.', 'wait', title, session.remainingSeconds)
  elseif startBlocked then
    local hold = type(startBlocked) == 'table' and startBlocked or {reason = startBlocked}
    result.hold = {kind = hold.kind or M.holdKind(hold.code), reason = hold.reason, hint = hold.hint,
      carName = hold.carName or session.currentVehicleName, partCount = hold.partCount or #(hold.partChanges or {})}
    result.step = step('hold', 'Pass on hold', result.hold.reason, result.hold.kind, (result.hold.carName and result.hold.carName .. ': ' or '') .. (result.hold.reason or 'Pass on hold'))
  elseif runtime.playerPass and runtime.phase == 'armed' then
    result.step = step('stageRoute', 'Head to staging', 'Follow the route to the ' .. (runtime.playerLane or 'assigned') .. ' lane.', 'act')
  elseif runtime.playerPass and (runtime.phase == 'preparing' or runtime.phase == 'approaching') then
    result.step = step('stage', 'Stage in the ' .. (runtime.playerLane or 'assigned') .. ' lane', "Stop in the beams. Don't launch yet.", 'act')
  elseif runtime.playerPass and runtime.phase == 'racing' then
    result.step = step('launch', 'Launch on green', 'Drive through the finish.', 'go')
  elseif runtime.playerPass and runtime.phase == 'cooldown' then
    result.step = step('passComplete', 'Pass complete', 'Slow down safely.', 'done')
  elseif paddock.playerCalled then
    local spot = paddock.playerSpotName or 'your paddock space'
    result.step = step('called', 'Go to ' .. spot, 'Follow the route with ' .. (session.currentVehicleName or 'your registered car') .. '.', 'act')
  elseif paddock.playerUpcoming then
    result.step = step('groupNext', 'Your group is next', 'Get ' .. (session.nextVehicleName or session.currentVehicleName or 'your car') .. ' ready.', 'act')
  elseif session.nextVehicleName then
    result.step = step('carNext', 'Next car: ' .. session.nextVehicleName, 'Wait for its group call.')
  else
    local group = paddock.groupNumber and M.count(paddock.groupNumber, paddock.groupCount, 'Group') or 'Next group'
    result.step = step('waitForGroup', group .. ' on track', 'Wait for your group call.', 'wait', group .. ' on track', waitSeconds and waitSeconds > 0 and waitSeconds or nil)
  end
  return result
end

return M
