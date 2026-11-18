-- Owns the Motorsport Event display card.
-- motorsportEvents.lua supplies event/runtime snapshots; drag/parking.lua supplies group status; drag/spectatorHud.lua docks the
-- card while spectating. overhaul/lib/ui/eventDisplay.lua publishes the card; OverhaulEventDisplay.vue draws it.
local M = {}
local grid = require('overhaul/events/motorsportEvents/drag/grid')
local qualifying = require('overhaul/events/motorsportEvents/drag/qualifying')
local hud = require('overhaul/lib/ui/eventDisplay')
local OWNER = 'motorsport'
local shown, timer, dock = false, 0, 'left'

local playerStatus = require('overhaul/events/motorsportEvents/playerStatus')
local compactSteps = {registrationRoute = true, registrationChoose = true, registrationReady = true,
  checkInRoute = true, checkInInspect = true, waitForSession = true, scheduleUnavailable = true}

local function fact(meta, label, value, tone)
  if value and value ~= '' then meta[#meta + 1] = {label = label, value = value, tone = tone} end
end

local function ordinal(place)
  local suffix = place % 100 >= 11 and place % 100 <= 13 and 'th'
    or ({[1] = 'st', [2] = 'nd', [3] = 'rd'})[place % 10] or 'th'
  return tostring(place) .. suffix
end

local function resultSummary(status)
  local outcome = status.outcome or {}
  -- The strip already says the event is complete; without a placing this line is the payout.
  local placing = outcome.place and ordinal(outcome.place) or outcome.label or 'Payout'
  return {text = placing .. (outcome.className and ' in ' .. outcome.className or ''), reward = outcome.reward or 0}
end

local nativeResultLabels = {jumping = 'Red light', outOfLane = 'Out of lane', crashed = 'Crashed',
  stationary = 'Stopped too long', stationaryTooLong = 'Stopped too long'}
local function displayTimeslip(slip)
  if not slip then return nil end
  local needsLabels = false
  for _, lane in ipairs(slip.lanes or {}) do
    if type(lane.result) == 'string' and lane.result:match('^missions%.') then needsLabels = true; break end
  end
  if not needsLabels then return slip end
  local result = {}
  for key, value in pairs(slip) do result[key] = value end
  result.lanes = {}
  for index, lane in ipairs(slip.lanes or {}) do
    local row = {}
    for key, value in pairs(lane) do row[key] = value end
    if type(row.result) == 'string' and row.result:match('^missions%.') then
      local key = row.result:match('^missions%.dragRace%.gameplay%.disqualified%.(.+)$')
      row.result = nativeResultLabels[key] or 'Disqualified'
    end
    result.lanes[index] = row
  end
  return result
end

-- Renders the shared producer's instruction; it never guesses who can still race.
function M.view(eventState, runtime, message, waitSeconds, startBlockedReason, paddock, session, status, watching)
  if not eventState then return nil end
  runtime, session, paddock = runtime or {}, session or {}, paddock or {}
  status = status or playerStatus.resolve(eventState, runtime, session, paddock, nil, nil, startBlockedReason, waitSeconds)
  if not status or status.role == 'withdrawn' then return nil end
  if eventState.phase == 'complete' and eventState.venueSessionDay == nil then return nil end
  local step = status.step or {}
  local view = {id = eventState.id, icon = 'raceFlag',
    meta = {}, matchups = {}, call = step.short, callKind = step.tone,
    phase = status.round and status.round.name or 'Qualifying',
    status = step.title, tone = 'idle'}
  view.compact = compactSteps[step.id] == true
  -- Before racing the card is the status line and the event's name. Once racing, the class and round replace the name.
  if view.compact then view.title, view.phase, view.status = eventState.name, nil, nil end
  view.oneRow = step.id == 'waitForSession'
  if view.oneRow then
    local nextSession = session.nextLabel or 'Next session'
    view.call = nextSession .. (step.countdown and ' in ' .. playerStatus.duration(step.countdown) or ' on Day ' .. tostring(session.nextDay or session.day or 1))
    -- A timed wait is also sent as a label and seconds, so the card can draw the time as a value.
    if step.countdown then view.wait = {label = nextSession .. ' in', seconds = step.countdown} end
  end
  if view.compact then return view end
  -- The spectator dock owns the active class and matchup.
  view.tag = not watching and eventState.className or nil
  view.note = step.text ~= step.short and step.text ~= '' and step.text or nil
  -- The runner retains its graded slip after clearing playerPass, until the next pass.
  if runtime.playerPass or runtime.timeslip and runtime.timeslip.graded then
    view.timeslip = displayTimeslip(runtime.timeslip)
  end
  if status.role == 'done' then
    -- The result line names the class.
    view.tag, view.phase, view.status, view.tone = nil, nil, nil, 'done'
    view.result = resultSummary(status)
    view.note = not watching and (status.finishEvent and status.finishEvent.reason or 'See results on your phone, or keep watching.') or nil
    return view
  end
  if status.role == 'out' then
    -- The status line already says the outcome and that the player is watching.
    view.phase, view.status, view.call, view.callKind = nil, nil, step.short, step.tone
    -- Keep the outcome reason. While watching, the dock owns Finish Event and its disabled reason.
    local finish = status.finishEvent
    local reason = status.outcome and status.outcome.reason
    if watching then view.note = reason
    else
      local prefix = reason and reason:gsub('%.$', '') .. '. ' or ''
      view.note = finish and (finish.reason or finish.allowed and prefix .. 'Finish Event is on your phone.') or nil
    end
  end
  -- The car is named once, as a fact: during the player's pass, and under a hold (whose status line is the reason only).
  -- A parts hold already names the car in its sentence.
  local hold = status.hold
  if hold and (hold.partCount or 0) == 0 then fact(view.meta, 'Car', hold.carName or session.currentVehicleName)
  elseif runtime.playerPass and not hold then fact(view.meta, 'Car', session.currentVehicleName) end
  fact(view.meta, 'Day', session.day and playerStatus.count(session.day, session.totalDays))
  if eventState.phase == 'qualifying' or eventState.phase == 'playerQualifying' then
    local round = eventState.spectatorRound or qualifying.roundInfo(eventState.entrants or {})
    fact(view.meta, 'Round', round and playerStatus.count(round.number, round.maxRounds))
  end
  if status.role == 'entrant' and paddock.groupNumber then
    -- Groups are called from the paddock; "On track" belongs to the matchup row alone. When the called group is the
    -- player's own, that is one fact, not two.
    if paddock.playerCalled then fact(view.meta, 'Your group, called', playerStatus.count(paddock.groupNumber, paddock.groupCount), 'accent')
    else
      fact(view.meta, 'Group called', playerStatus.count(paddock.groupNumber, paddock.groupCount))
      if paddock.playerUpcoming and paddock.upcomingGroupNumber then
        fact(view.meta, 'Your group', playerStatus.count(paddock.upcomingGroupNumber, paddock.groupCount), 'accent')
      end
    end
  end
  local byId, names = {}, {}
  for _, entrant in ipairs(eventState.entrants or {}) do byId[entrant.id] = entrant end
  for _, racer in ipairs(runtime.racers or {}) do
    local entrant = byId[racer.entrantId]
    if entrant then names[#names + 1] = entrant.name or entrant.model end
  end
  if not watching and #names > 0 then view.matchups[1] = {label = 'On track', names = names} end
  if not watching and #names == 0 and status.role == 'entrant' then
    local ids = paddock.nextEntrantIds
    if ids then
      for _, id in ipairs(ids) do if byId[id] then names[#names + 1] = byId[id].name end end
    else
      local heat = grid.queue(eventState)[1]
      for _, entrant in ipairs(heat and heat.entrants or {}) do names[#names + 1] = entrant.name end
    end
    if not watching and #names > 0 then view.matchups[1] = {label = 'On track next', names = names} end
  end
  if not runtime.playerPass and status.role == 'entrant' and (waitSeconds or 0) > 0 then
    view.countdown = {label = 'Your pass in', seconds = waitSeconds}
  end
  if hold then
    -- The status line carries the reason; 'Pass on hold' is said once, beside the class.
    view.holdKind, view.call, view.note, view.status = hold.kind, nil, nil, nil
    if hold.reason then view.phase = 'Pass on hold' end
    if (hold.partCount or 0) > 0 then
      view.hold = tostring(hold.partCount) .. ' parts changed on ' .. (hold.carName or 'your car') .. '. See phone.'
    else view.hold = hold.reason or 'Pass on hold' end
  end
  return view
end

-- The card sits on the left; while spectating it moves to the right edge, clear of the spectator controls.
function M.setDock(value)
  dock = value == 'right' and 'right' or 'left'
  local current = shown and hud.get(OWNER)
  if current then current.dock = dock; hud.set(OWNER, current) end
end

function M.clear()
  timer = 0
  if not shown then return end
  shown = false
  hud.clear(OWNER)
end

function M.update(eventState, runtime, message, waitSeconds, dtSim, startBlockedReason, paddock, session, status)
  hud.tick(dtSim or 0)
  timer = timer + (dtSim or 0)
  if timer < .25 then return end
  timer = 0
  if type(status) == 'function' then status = status() end
  local view = M.view(eventState, runtime or {phase = 'idle'}, message, waitSeconds, startBlockedReason, paddock, session, status, dock == 'right')
  if not view then M.clear(); return end
  view.dock = dock
  shown = true
  hud.set(OWNER, view)
end

return M
