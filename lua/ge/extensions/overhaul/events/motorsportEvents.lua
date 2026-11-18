-- Owns the Motorsport lifecycle, actions, and UI state.
-- Helpers live in events/motorsportEvents/; storage.lua owns persistence and drag/runner.lua owns physical passes.
local M = {}
-- Toasts join the Event display stack (motorsportEvents/notify.lua); it is loaded when the first one is sent.
local function toast(text, kind, seconds) return require('overhaul/events/motorsportEvents/notify')(text, kind, seconds) end
M.dependencies = {'overhaul_career_career', 'overhaul_career_garage_switchMap', 'overhaul_shell_patches', 'overhaul_world_facilities', 'overhaul_integration_services_dragScores', 'overhaul_integration_services_parking', 'gameplay_drag_core', 'gameplay_drag_dragBridge', 'gameplay_drag_poi', 'gameplay_traffic', 'gameplay_sites_sitesManager', 'gameplay_missions_unlocks', 'gameplay_rawPois'}
local storage = require('overhaul/events/motorsportEvents/storage')
local betting = require('overhaul/events/motorsportEvents/drag/betting')
local saveStore = require('overhaul/lib/save/store')
local roster = require('overhaul/events/motorsportEvents/drag/roster')
local qualifying = require('overhaul/events/motorsportEvents/drag/qualifying')
local qualifyingSchedule = require('overhaul/events/motorsportEvents/drag/qualifyingSchedule')
local spectatorQualifying = require('overhaul/events/motorsportEvents/drag/spectatorQualifying')
local bracket = require('overhaul/events/motorsportEvents/drag/bracket')
local runner = require('overhaul/events/motorsportEvents/drag/runner')
local rewards = require('overhaul/events/motorsportEvents/rewards')
local policy = require('overhaul/events/motorsportEvents/drag/eventPolicy')
local traffic = require('overhaul/events/motorsportEvents/traffic')
local parking = require('overhaul/events/motorsportEvents/drag/parking')
local missionMarkers = require('overhaul/events/motorsportEvents/drag/missionMarkers')
local simulation = require('overhaul/events/motorsportEvents/drag/simulation')
local eventDisplay = require('overhaul/events/motorsportEvents/drag/eventDisplay')
local venues = require('overhaul/events/motorsportEvents/drag/venues')
local grid = require('overhaul/events/motorsportEvents/drag/grid')
local registration = require('overhaul/events/motorsportEvents/registration')
local interactions = require('overhaul/events/motorsportEvents/venueInteractions')
local definitions = require('overhaul/events/motorsportEvents/definitions')
local catalog = require('overhaul/events/motorsportEvents/drag/catalog')
local classFields = require('overhaul/events/motorsportEvents/classFields')
local weekend = require('overhaul/events/motorsportEvents/weekend')
local weekendProgress = require('overhaul/events/motorsportEvents/weekendProgress')
local playerStatus = require('overhaul/events/motorsportEvents/playerStatus')
local classRules = require('overhaul/events/motorsportEvents/drag/classes')
local eventDecor = require('overhaul/events/motorsportEvents/eventDecor')
local decorSynced, decorVenue, decorPhase = false
local function syncDecor(venue)
  local phase = venue and venue.phase
  if decorSynced and decorVenue == venue and decorPhase == phase then return end
  decorSynced, decorVenue, decorPhase = true, venue, phase
  eventDecor.sync(venue)
end
local function shutdownDecor()
  eventDecor.shutdown()
  decorSynced, decorVenue, decorPhase = false, nil, nil
end
local offers = require('overhaul/events/motorsportEvents/offers')
local eventClock = require('overhaul/events/motorsportEvents/eventClock')
local background = require('overhaul/events/motorsportEvents/background')
local skipToGroup = require('overhaul/events/motorsportEvents/skipToGroup')
local calendarPoll, offerCacheKey, offerCache = 0, nil, nil
local venueNearby = true
local message, autoNextAt, clock = '', nil, 0
local startBlockedReason
local startBlocked
local nextPassAt = 0
local nextPlayerCheckAt = 0
local lastInventoryId
local lastSessionKey
local sessionWasWaiting = false
local spectatorPass
local spectatorArrivalChoice = false
local spectatorChoicePending, spectatorStoppedSeconds = false, 0
local spectatorActivitySyncPending = false
local spectatorActivityRetryIntervalSeconds = 1
local spectatorActivityRetrySeconds = 0
local spectatorActivitySyncId = 0
-- The always-mounted overlay only needs these flags until it becomes visible.
function M.getSpectatorActivity()
  return {watching = runner.isWatching(), arrivalChoice = spectatorArrivalChoice}
end
local function publishSpectatorActivity()
  local activity = M.getSpectatorActivity()
  activity.syncId = spectatorActivitySyncId
  guihooks.trigger('MotorsportSpectatorActivity', activity)
end
function M.requestSpectatorActivity()
  local activity = M.getSpectatorActivity()
  spectatorActivitySyncId = spectatorActivitySyncId + 1
  spectatorActivitySyncPending = activity.arrivalChoice or activity.watching
  spectatorActivityRetrySeconds = spectatorActivityRetryIntervalSeconds
  publishSpectatorActivity()
end
function M.acknowledgeSpectatorActivity(syncId)
  if syncId == spectatorActivitySyncId then spectatorActivitySyncPending = false end
end
M.onUiReady = M.requestSpectatorActivity
local function updateSpectatorActivitySync(dtReal)
  if not spectatorActivitySyncPending then return end
  if not spectatorArrivalChoice and not runner.isWatching() then
    spectatorActivitySyncPending = false
    return
  end
  spectatorActivityRetrySeconds = spectatorActivityRetrySeconds - math.max(0, dtReal or 0)
  if spectatorActivityRetrySeconds > 0 then return end
  spectatorActivityRetrySeconds = spectatorActivityRetryIntervalSeconds
  publishSpectatorActivity()
end
local function setArrivalChoice(value)
  if spectatorArrivalChoice == value then return end
  spectatorArrivalChoice = value
  publishSpectatorActivity()
end
local function clearArrivalChoice()
  if spectatorArrivalChoice and simTimeAuthority then simTimeAuthority.popPauseRequest('motorsportArrival') end
  setArrivalChoice(false)
  spectatorChoicePending, spectatorStoppedSeconds = false, 0
end
local function showSpectatorChoice()
  if spectatorArrivalChoice or spectatorChoicePending then return end
  spectatorChoicePending, spectatorStoppedSeconds = true, 0
end
local function needsOutcomeChoice(eventState)
  return eventState ~= nil and not eventState.playerOutcomeAcknowledged
    and (weekendProgress.spectatorOnly(eventState) or eventState.playerEliminated == true)
end

local function activeCareer() return overhaul_career_career and overhaul_career_career.isActive() end
function M.isDevToolsEnabled()
  return activeCareer() and overhaul_shell_extensionManager and overhaul_shell_extensionManager.isDevKeyValid(true) == true or false
end

local function event() return storage.get().event end
local function calendarState()
  if not activeCareer() then return {ready = false} end
  local state, eventState = storage.get(), event()
  if offers.sync(state, eventState) then storage.save(); offerCacheKey = nil end
  local now, frozen = offers.clock()
  local key = table.concat({getCurrentLevelIdentifier() or '', tostring(now and math.floor(now / 1440)),
    tostring(frozen), tostring(eventState and eventState.id), tostring(eventState and eventState.phase), tostring(state.rotation and state.rotation.position),
    tostring(state.rotation and state.rotation.offerSerial)}, ':')
  if key ~= offerCacheKey then
    offerCache = offers.view(state, eventState, getCurrentLevelIdentifier())
    offerCacheKey = key
  end
  if frozen and state.rotation then
    local r, realNow = state.rotation, eventClock.now()
    if offerCache.cooldown then offerCache.remainingSeconds = math.max(0, (r.availableAt or realNow) - realNow)
    elseif offerCache.offer then offerCache.expiresInSeconds = math.max(0, (r.offerExpiresAt or realNow) - realNow) end
  end
  return offerCache
end
local function racingEvent(eventState) return spectatorQualifying.context(eventState) or eventState end
local function paddockState(view, runtime)
  local state = parking.status()
  if not view or runtime.phase == 'idle' or not parking.previewNext then return state end
  local eventState = event()
  local inFlight = eventState and eventState.id == view.id and eventState.inFlight or view.inFlight
  local qualifyingPhase = view.phase == 'qualifying' or view.phase == 'playerQualifying'
  local skipPlayer = qualifyingPhase and runner.isWatching() and (view.qualifyingCompression == true or view.spectatorQualifyingKey ~= nil)
  state.upNextEntrantIds = parking.previewNext(view, inFlight, skipPlayer)
  return state
end
local function claimedHeat(eventState)
  eventState = racingEvent(eventState)
  return runner.status().phase ~= 'idle'
    or eventState ~= nil and parking.claimedHeats ~= nil and #parking.claimedHeats(eventState) > 0
end
local function venueEvent(eventState)
  if not eventState or eventState.level ~= getCurrentLevelIdentifier() then return nil end
  if definitions.event(eventState).schedule and not venueNearby then return nil end
  if eventState.phase == 'complete' then
    local now = offers.clock()
    return now and eventState.venueSessionDay == math.floor(now / 1440) and eventState or nil
  end
  if eventState.checkInVersion ~= 1 then return eventState end
  local gate = weekendProgress.spectatorOnly(eventState) and weekendProgress.gate(eventState, claimedHeat(eventState)) or weekendProgress.inspectionGate(eventState)
  if gate.allowed and (eventState.venueArrivalDay == gate.requiredDay or weekendProgress.checkedIn(eventState)) then return eventState end
end
local function advanceWeekend(eventState)
  local result = weekendProgress.advance(eventState)
  if result.ok and result.changed then
    parking.stop()
    startBlockedReason = nil
    autoNextAt = math.max(clock, nextPassAt)
    local gate = weekendProgress.gate(eventState)
    message = gate.allowed and ('Next session: ' .. eventState.className .. '.') or gate.message
  end
  return result
end
local function continueAfterRefund(eventState)
  if weekendProgress.enabled(eventState) and (#(eventState.classes or {}) > 0 or weekend.nextPlayer(eventState)) then return advanceWeekend(eventState) end
  return weekend.prepareNext(eventState)
end
local function prepareQualifying(eventState)
  if spectatorQualifying.context(eventState) then return true end
  if not qualifyingSchedule.enabled(eventState) then
    if weekendProgress.enabled(eventState) and eventState.phase == 'eliminations' and not claimedHeat(eventState) then
      local advanced = advanceWeekend(eventState)
      return advanced.ok, advanced.error
    end
    return true
  end
  local plan, error = qualifyingSchedule.prepare(eventState, nil, parking.claimedHeats and parking.claimedHeats(eventState))
  if not plan then return false, error end
  local completed = qualifyingSchedule.completeRound(eventState, {physicalOnly = runner.isWatching()})
  if not completed.ok then return false, completed.error end
  if completed.simulatedCount > 0 then weekend.sync(eventState) end
  local advanced
  if completed.complete and weekendProgress.enabled(eventState) then
    advanced = advanceWeekend(eventState)
  end
  if completed.simulatedCount > 0 then storage.save() end
  if advanced and not advanced.ok then return false, advanced.error end
  return true
end
local function updateSpectatorQualifying(eventState, start)
  local view = spectatorQualifying.context(eventState)
  if view then
    if not runner.isWatching() then
      local claims = parking.claimedHeats and parking.claimedHeats(view) or {}
      if spectatorPass and spectatorPass.key == view.spectatorQualifyingKey then claims[#claims + 1] = spectatorPass.ids end
      spectatorQualifying.exit(eventState, claims)
    end
    if runner.status().phase == 'idle' and spectatorQualifying.finished(eventState) then
      parking.stop()
      local seeded = spectatorQualifying.reseed(eventState)
      if not seeded.ok then startBlockedReason, message = seeded.error, seeded.error; return view end
      spectatorQualifying.clear(eventState)
      storage.save()
      view = nil
    end
  end
  if start and not view and eventState.qualifyingCompression == true and runner.isWatching() and runner.status().phase == 'idle' then
    local qualifyingPhase = eventState.phase == 'qualifying' or eventState.phase == 'playerQualifying'
    local queuedNpc = qualifyingPhase and parking.nextPair and parking.nextPair(eventState, true)
    local claimedElimination = eventState.phase == 'eliminations' and parking.claimedHeats and #parking.claimedHeats(eventState) > 0
    if not queuedNpc and not claimedElimination then
      view = spectatorQualifying.start(eventState)
      if view then
        parking.stop()
        startBlockedReason = nil
        autoNextAt = math.max(clock, nextPassAt)
        storage.save()
      end
    end
  end
  return view or eventState
end
local function emit()
  local eventState = activeCareer() and event() or nil
  if needsOutcomeChoice(eventState) then showSpectatorChoice() end
  local venue = activeCareer() and venueEvent(event()) or nil
  traffic.sync(venue ~= nil, venue)
  syncDecor(venue)
  storage.save()
  guihooks.trigger('motorsportEventsUpdated', M.getState())
end

local function partsHoldMessage(changes)
  local count = #(changes or {})
  if count == 0 then return [[Your car's parts changed since registration. Open Motorsport Events for details.]] end
  return [[Your car's parts changed since registration (]] .. count .. (count == 1 and ' part' or ' parts') .. [[). Open Motorsport Events and tap See changes.]]
end

local function holdPlayerStart(reason, code, entrant, vehicle)
  local changes = code == 'configuration_changed' and roster.partChanges(entrant, vehicle) or nil
  local changed = startBlockedReason ~= reason or not startBlocked or startBlocked.code ~= code
  if not changed and changes then
    local previous = startBlocked.partChanges or {}
    changed = #changes ~= #previous
    for index, change in ipairs(changes) do
      local old = previous[index]
      if not old or change.slot ~= old.slot or (change.registered and change.registered.name) ~= (old.registered and old.registered.name)
        or (change.current and change.current.name) ~= (old.current and old.current.name) then changed = true; break end
    end
  end
  if changed then
    local firstHold = startBlockedReason ~= reason or not startBlocked or startBlocked.code ~= code
    startBlockedReason, message = reason, reason
    startBlocked = {reason = reason, code = code, partChanges = changes, kind = playerStatus.holdKind(code),
      hint = code == 'configuration_changed' and 'Restore the registered parts. See changes on the phone.' or nil,
      carName = entrant and (entrant.vehicleName or entrant.model), partCount = #(changes or {})}
    if code == 'configuration_changed' and firstHold then toast(partsHoldMessage(changes), 'bad', 10) end
    emit()
  end
  return {ok = false, error = reason, reason = code}
end

function M.getPlayerProgress(eventState)
  local playerProgress = {}
  for _, row in ipairs(eventState and eventState.registrations or {}) do
    local competition = row.classId == eventState.activeClassId and eventState or nil
    for _, class in ipairs(eventState.classes or {}) do
      if class.id == (row.classId or row.declaredClassId) then competition = class; break end
    end
    local outcome = competition and bracket.playerOutcome(competition.bracket, row.id)
    if outcome then playerProgress[weekendProgress.inspectionKey(row)] = outcome end
  end
  return playerProgress
end

local function resolvePlayerStatus(eventState, runtime, session, paddock, registrationState, checkInState, blocked)
  if not eventState then return nil end
  -- Replayed NPC qualifying changes what is watched, never the player's outcome.
  local watched = eventState.spectatorQualifyingKey and eventState or spectatorQualifying.context(eventState)
  if eventState.spectatorQualifyingKey then eventState = event() end
  session = session or weekendProgress.session(eventState, claimedHeat(eventState)) or {}
  registrationState = registrationState or {atRegistration = eventState.phase == 'registration'
    and interactions.isAtRegistration and interactions.isAtRegistration(eventState)}
  checkInState = checkInState or {atCheckIn = session.checkInRequired
    and interactions.isAtCheckIn and interactions.isAtCheckIn(eventState)}
  local statusRuntime = {}
  for key, value in pairs(runtime or {}) do statusRuntime[key] = value end
  statusRuntime.watching = runner.isWatching()
  if statusRuntime.pendingBet == nil then statusRuntime.pendingBet = betting.pending() end
  -- The native runner enters its racing session before the car reaches the beams.
  -- Feed the shared producer the actual staging step until its tree has started.
  if statusRuntime.playerPass and statusRuntime.phase == 'racing' and statusRuntime.treeLive == false then
    statusRuntime.phase = 'approaching'
  end
  local hold = blocked
  if not hold and startBlockedReason then
    hold = startBlocked and startBlocked.reason == startBlockedReason and startBlocked or startBlockedReason
  end
  local status = playerStatus.resolve(eventState, statusRuntime, session,
    paddock or paddockState(eventState, runtime), registrationState, checkInState,
    hold, math.max(0, math.ceil(nextPassAt - clock)))
  -- All surfaces share the watched session, while entries and Finish permission
  -- remain authoritative to the saved competition above.
  if watched and status.step.id == 'spectating' then
    local round = watched.spectatorRound or {}
    status.round = {name = 'Qualifying', number = round.number, of = round.maxRounds}
    status.step.short = 'Watching ' .. status.round.name:lower()
  end
  return status
end

local displayStatusEvent, displayStatusRuntime, displayStatusSession, displayStatusBlocked
local function currentDisplayStatus()
  return resolvePlayerStatus(displayStatusEvent, displayStatusRuntime, displayStatusSession, nil, nil, nil, displayStatusBlocked)
end
-- The publisher invokes this synchronously on a HUD tick; other frames only
-- replace the arguments, without allocating a closure or resolving status.
local function deferredDisplayStatus(eventState, runtime, session, blocked)
  displayStatusEvent, displayStatusRuntime, displayStatusSession, displayStatusBlocked = eventState, runtime, session, blocked
  return currentDisplayStatus
end

-- A class session is created only after its player finishes qualifying.
-- Until then, its registered field still needs the same ordering as a session.
local function resultStandings(eventState)
  if not eventState then return {}, {} end
  local byClass, fields, activeId = {}, {}, eventState.activeClassId
  for _, field in ipairs(classFields.fields(eventState)) do
    fields[field.id] = field.all
    local entrants = field.all
    if field.registration and not field.session then
      entrants = {}
      for _, entrant in ipairs(field.all) do
        if entrant == field.registration then
          local player = {}
          for key, value in pairs(entrant) do if key ~= 'qualifyingOpponents' then player[key] = value end end
          player.player, player.name = true, entrant.name or 'You'
          entrants[#entrants + 1] = player
        else entrants[#entrants + 1] = entrant end
      end
    end
    byClass[field.id] = qualifying.standings(entrants)
    if not activeId and field.registration
      and classFields.registrationId(field.registration) == eventState.activeRegistrationId then activeId = field.id end
  end
  -- Dispatch puts the player first; the frozen class field owns tie order.
  -- Spectator dispatch contains only opponents; results keep the full class.
  local standings = eventState.spectatorQualifyingKey and byClass[activeId]
    or qualifying.standings(eventState.entrants, fields[activeId])
  if activeId then byClass[activeId] = standings end
  return standings, byClass
end

function M.getState()
  if not startBlockedReason or startBlocked and startBlocked.reason ~= startBlockedReason then startBlocked = nil end
  local eventState = activeCareer() and event() or nil
  local playerProgress = M.getPlayerProgress(eventState)
  local view = eventState and racingEvent(eventState)
  local standings, classStandings = resultStandings(view)
  local runtime = runner.status()
  local calendar = deepcopy(calendarState())
  local availableVenues = {}
  if activeCareer() then
    for _, data in ipairs(venues.list(getCurrentLevelIdentifier())) do
      availableVenues[#availableVenues + 1] = {id = data.strip.id, name = _tr(data.strip.name or data.strip.id)}
    end
  end
  local session = view and weekendProgress.session(view, claimedHeat(eventState)) or nil
  local paddock = paddockState(view, runtime)
  local registrationState = activeCareer() and registration.getState(event()) or nil
  local checkInState = eventState and registration.checkInState(eventState) or nil
  local status = resolvePlayerStatus(view, runtime, session, paddock, registrationState, checkInState)
  return {playerStatus = status, round = status and status.round, nextPairing = status and status.nextPairing,
    careerActive = activeCareer() == true, devTools = M.isDevToolsEnabled(),
    calendar = calendar,
    skipToGroup = eventState and skipToGroup.status(eventState, runtime) or nil,
    availableVenues = availableVenues,
    canFinishWeekend = status ~= nil and status.finishEvent.allowed,
    event = view, runtime = runtime, message = message, playerProgress = playerProgress, paddock = paddock,
    startBlockedReason = activeCareer() and event() and startBlockedReason or nil,
    startBlocked = activeCareer() and event() and startBlockedReason and startBlocked and startBlocked.reason == startBlockedReason and startBlocked or nil,
    registration = registrationState,
    checkIn = checkInState,
    session = session,
    qualifyingRound = view and (view.spectatorRound or (view.phase == 'qualifying' or view.phase == 'playerQualifying') and qualifying.roundInfo(view.entrants)) or nil,
    waitSeconds = math.max(0, math.ceil(nextPassAt - clock)), watching = runner.isWatching(),
    standings = standings, classStandings = classStandings}
end

function M.isDragDispatchActive()
  local eventState = activeCareer() and event() or nil
  return eventState ~= nil and eventState.phase ~= 'registration' and eventState.phase ~= 'complete' and weekendProgress.checkedIn(eventState)
    and venueNearby and weekendProgress.gate(eventState, claimedHeat(eventState)).allowed and eventState.level == getCurrentLevelIdentifier()
end

function M.listEventDefinitions() return definitions.available(getCurrentLevelIdentifier()) end

local function startEvent(definitionId, offer)
  if event() and event().phase ~= 'complete' then return {ok = false, error = 'Finish or cancel the current event first.'} end
  local level = getCurrentLevelIdentifier()
  local ok, snapshot, definitionError = pcall(definitions.snapshot, definitionId, level)
  if not ok then return {ok = false, error = tostring(snapshot)} end
  if not snapshot then return {ok = false, error = definitionError} end
  if offer then
    snapshot.eventDefinition.leagueIds = {offer.leagueId}
    snapshot.eventDefinition.stripId = offer.stripId
  end
  local valid, why = pcall(function()
    snapshot.classDefinitions, snapshot.configDefinitions = catalog.listClasses(), catalog.drivers()
    definitions.validateCatalog(snapshot.classDefinitions, snapshot.configDefinitions, snapshot.competition)
  end)
  if not valid then return {ok = false, error = tostring(why)} end
  local strip = venues.choose(level, snapshot.eventDefinition.stripId)
  if not strip then return {ok = false, error = 'This map has no supported two-lane drag venue.'} end
  local venueName = _tr(strip.strip.name or strip.strip.id)
  local time = overhaul_world_weather and overhaul_world_weather.getUiState()
  local eventState = storage.replace({version = 2, formatVersion = 2, qualifyingCompression = snapshot.eventDefinition.qualifyingCompression, discipline = 'drag', name = snapshot.eventDefinition.name:gsub('{venue}', function() return venueName end), className = 'Registration',
    level = level, stripId = strip.strip.id, stripName = venueName,
    stripFile = strip._originFile, phase = 'registration', entrants = {}, classes = {}, registrations = {},
    eventDay = time and time.dayIndex,
    competition = snapshot.competition, eventDefinition = snapshot.eventDefinition, definitionId = snapshot.definitionId,
    classDefinitions = snapshot.classDefinitions, configDefinitions = snapshot.configDefinitions,
    prizes = rewards.prizes(snapshot), rewardPaid = false})
  if offer then eventState.acceptedOfferId, eventState.offeredLeagueId = offer.id, offer.leagueId end
  weekendProgress.initialize(eventState, true)
  if eventState.weekendCalendar then
    eventState.startWorldMinute = eventState.weekendCalendar.anchorDay * 1440 + (snapshot.eventDefinition.stages.qualifying.minuteOfDay or 0)
  end
  lastSessionKey, sessionWasWaiting = nil, false
  startBlockedReason = nil
  registration.begin(eventState)
  nextPassAt, autoNextAt = clock, nil
  local vehicleId = be:getPlayerVehicleID(0)
  lastInventoryId = overhaul_career_garage_inventory and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehicleId)
  interactions.routeRegistration(eventState)
  message = 'Park in the marked registration space with your race cars nearby to pick classes.'
  emit()
  return {ok = true}
end

function M.devStartEvent(definitionId)
  if not M.isDevToolsEnabled() then return {ok = false, error = 'Developer key required.'} end
  return startEvent(definitionId)
end

-- Every league the daily rotation can offer, in rotation order, for the tester menu.
function M.devLeagues()
  local config = definitions.data().rotation
  local list = {}
  for _, id in ipairs(config and config.leagueIds or {}) do
    local league = definitions.league(id)
    list[#list + 1] = {value = id, label = league and league.name or id}
  end
  return list
end

function M.devForceLeague(leagueId)
  if not M.isDevToolsEnabled() then return {ok = false, error = 'Developer key required.'} end
  local eventState = event()
  if eventState and eventState.phase ~= 'complete' then return {ok = false, error = 'Finish or withdraw from the current event first.'} end
  calendarState()
  local result = offers.forceLeague(storage.get(), leagueId)
  if not result.ok then return result end
  storage.save()
  offerCacheKey = nil
  calendarState()
  emit()
  return result
end

function M.acceptOffer(offerId)
  if not activeCareer() then return {ok = false, error = 'Career required.'} end
  -- Recheck installed fields at the transaction boundary.
  offerCacheKey = nil
  local calendar = calendarState()
  local offer = calendar and calendar.offer
  if not offer or offer.id ~= offerId then return {ok = false, error = 'This daily offer has changed. Refresh the event app.'} end
  if not offer.available then return {ok = false, error = offer.unavailableReason} end
  return startEvent(offer.definitionId, offer)
end

function M.advanceOffer(offerId)
  if not activeCareer() then return {ok = false, error = 'Career required.'} end
  local calendar = calendarState()
  if not calendar or not calendar.canAdvanceOffer or (calendar.offer and calendar.offer.id or calendar.id) ~= offerId then
    return {ok = false, error = 'This offer can no longer be advanced.'}
  end
  local result = offers.advance(calendar.nextOfferWorldMinute)
  offerCacheKey = nil
  if result.ok then calendarState(); emit() end
  return result
end

function M.declineOffer(offerId)
  if not activeCareer() then return {ok = false, error = 'Career required.'} end
  offerCacheKey = nil
  local calendar = calendarState()
  if not calendar or not calendar.offer or calendar.offer.id ~= offerId then
    return {ok = false, error = 'This offer has changed. Refresh the event app.'}
  end
  local result = offers.decline(storage.get())
  offerCacheKey = nil
  calendarState()
  emit()
  return result
end

function M.withdrawEvent(eventId)
  if betting.pending() then return {ok = false, error = 'Finish this heat first.'} end
  local eventState = activeCareer() and event()
  if not eventState or eventState.id ~= eventId or eventState.phase == 'complete' then return {ok = false, error = 'This event is no longer active.'} end
  if eventState.pendingRefund then return {ok = false, error = 'Wait for the pending entry refund before withdrawing.'} end
  -- Paddock claims reserve future passes, including ones a wrecked car cannot
  -- attend. Only a dispatched pass needs protection from withdrawal.
  if runner.status().phase ~= 'idle' then return {ok = false, error = 'Finish the current heat before withdrawing.'} end
  runner.stop()
  runner.setWatching(false)
  spectatorQualifying.clear(eventState)
  parking.stop()
  eventState.phase, eventState.withdrawn, eventState.inFlight = 'complete', true, nil
  eventState.checkIn, eventState.venueArrivalDay, eventState.venueSessionDay = nil, nil, nil
  eventState.playerOutcomeAcknowledged = true
  spectatorPass, autoNextAt, startBlockedReason, startBlocked = nil, nil, nil, nil
  clearArrivalChoice()
  eventDisplay.clear()
  traffic.sync(false)
  syncDecor(nil)
  message = "You withdrew. Paid entry fees aren't refunded."
  offerCacheKey = nil
  gameplay_rawPois.clear()
  emit()
  return {ok = true}
end

function M.routeRegistration()
  local eventState = activeCareer() and event() or nil
  local ok = eventState ~= nil and interactions.routeRegistration(eventState) or false
  return {ok = ok, error = not ok and 'Registration or check-in is not available at this venue today.' or nil}
end

function M.checkIn()
  if not activeCareer() then return {ok = false, error = 'Career required.'} end
  local eventState = event()
  local wasCheckedIn = weekendProgress.checkedIn(eventState)
  local result = registration.checkIn(eventState)
  if not result.ok then return result end
  startBlockedReason = nil
  if not wasCheckedIn then nextPassAt, autoNextAt = clock, clock end
  nextPlayerCheckAt = clock
  message = 'Inspection passed. Checked in for ' .. (weekendProgress.gate(eventState).label or 'today') .. '. Wait for your group call.'
  gameplay_rawPois.clear()
  emit()
  if overhaul_career_saveSystem then saveStore.request('motorsport:checkIn') end
  return result
end

function M.arrive()
  local eventState = activeCareer() and event() or nil
  if not eventState or eventState.level ~= getCurrentLevelIdentifier() then return end
  if eventState.phase == 'complete' then
    if not venueEvent(eventState) or spectatorArrivalChoice then return end
    showSpectatorChoice()
    emit()
    return
  end
  local gate = weekendProgress.spectatorOnly(eventState) and weekendProgress.gate(eventState) or weekendProgress.inspectionGate(eventState)
  if not gate.allowed or spectatorArrivalChoice then return end
  if eventState.venueArrivalDay == gate.requiredDay and not weekendProgress.spectatorOnly(eventState) then return end
  eventState.venueArrivalDay = gate.requiredDay
  if weekendProgress.spectatorOnly(eventState) then
    showSpectatorChoice()
  end
  emit()
end

function M.dismissSpectatorChoice()
  local eventState = event()
  if eventState and needsOutcomeChoice(eventState) then eventState.playerOutcomeAcknowledged = true end
  clearArrivalChoice()
  emit()
  return {ok = true}
end

function M.attendAsSpectator()
  local eventState = activeCareer() and event() or nil
  if not spectatorArrivalChoice or not eventState or not (eventState.phase == 'complete' and venueEvent(eventState) or weekendProgress.spectatorOnly(eventState)) then return {ok = false, error = 'No spectator arrival choice is pending.'} end
  -- Walking mode refuses another enable request. Keep on-foot arrivals in place,
  -- as watchPass does; seated arrivals still move to the spectator area.
  if not (gameplay_walk and gameplay_walk.isWalking()) then
    local moved, moveError = interactions.teleportToSpectator(eventState)
    if not moved then return {ok = false, error = moveError} end
  end
  local watching, cameraError = runner.setWatching(true)
  if not watching then return {ok = false, error = cameraError} end
  eventState.playerOutcomeAcknowledged = true
  eventState.checkIn = {stage = weekendProgress.stage(eventState), spectatorOnly = true, inspections = {}}
  eventState.venueArrivalDay = weekendProgress.gate(eventState).requiredDay
  clearArrivalChoice()
  nextPassAt, autoNextAt, nextPlayerCheckAt = clock, clock, clock
  message = 'Spectating from the stands.'
  emit()
  return {ok = true}
end

function M.advanceDay()
  if not activeCareer() or not event() then return {ok = false, error = 'No active event.'} end
  if weekendProgress.spectatorOnly(event()) then return {ok = false, error = 'Your racing is finished. Choose Spectate or End day.'} end
  if runner.status().phase ~= 'idle' or claimedHeat(event()) then return {ok = false, error = 'Finish the current event heats before advancing the day.'} end
  local result = weekendProgress.advanceDay(event())
  if not result.ok then return result end
  autoNextAt, startBlockedReason = nil, nil
  message = 'The next session is open. Your entry is held.'
  gameplay_rawPois.clear()
  emit()
  if overhaul_career_saveSystem then saveStore.request('motorsport:advanceDay') end
  return result
end

function M.addRegistrations(rows, eventId)
  if not activeCareer() then return {ok = false, error = 'Career required.'} end
  local eventState = event()
  if not eventState or eventState.id ~= eventId then return {ok = false, error = 'The event changed. Review your entries again.'} end
  local result = registration.submit(eventState, rows)
  if not result.ok then return result end
  message = 'Entries registered and fees paid. Register more cars, or choose Start Event when ready.'
  emit()
  if overhaul_career_saveSystem then saveStore.request('motorsport:addRegistrations') end
  return result
end

function M.startRegisteredEvent(eventId)
  if not activeCareer() then return {ok = false, error = 'Career required.'} end
  local eventState = event()
  if not eventState or eventState.id ~= eventId or eventState.phase ~= 'registration' then return {ok = false, error = 'Registration is closed or the event changed.'} end
  if not eventState.registrationPaid or #(eventState.registrations or {}) == 0 then return {ok = false, error = 'Register at least one class entry first.'} end
  if eventState.pendingRefund then return {ok = false, error = 'Wait for the pending entry refund before starting.'} end
  if eventState.qualifyingSchedule and eventState.qualifyingSchedule.classes then
    for _, row in ipairs(eventState.registrations) do eventState.qualifyingSchedule.classes[row.declaredClassId] = nil end
  end
  if weekendProgress.enabled(eventState) then eventState.weekendStage = 'qualifying' end
  weekend.beginQualifying(eventState)
  weekendProgress.completeRegistrationInspection(eventState)
  parking.stop()
  autoNextAt, nextPassAt = weekendProgress.checkedIn(eventState) and clock or nil, clock
  gameplay_rawPois.clear()
  message = eventState.checkInVersion == 1 and 'Entry fees paid. Registration includes Day 1 inspection. Follow your group call.'
    or 'Entry fees paid. Your cars qualify alongside opponents from their declared classes. Both elapsed times count; a faster-than-index pass is a breakout.'
  emit()
  if overhaul_career_saveSystem then saveStore.request('motorsport:startRegisteredEvent') end
  return {ok = true}
end

-- Preserve the existing combined action for callers that explicitly submit a complete lineup.
function M.registerVehicles(rows)
  if not activeCareer() then return {ok = false, error = 'Career required.'} end
  local eventState = event()
  local result = registration.submit(eventState, rows)
  if not result.ok then return result end
  return M.startRegisteredEvent(eventState.id)
end

local function completeEvent(eventState)
  eventDisplay.clear()
  eventState.phase, eventState.winnerId = 'complete', eventState.bracket.winnerId
  local paid, rewardError = rewards.finish(eventState)
  if paid == false then
    eventState.phase, message, startBlockedReason = 'eliminations', rewardError, rewardError
    return
  end
  parking.stop()
  if eventState.formatVersion == 2 then
    eventState.totalReward = (eventState.totalReward or 0) + (eventState.reward or 0)
    weekend.sync(eventState)
    if not weekend.finishClass(eventState) then
      nextPassAt, autoNextAt = clock + policy.passInterval(eventState), clock + policy.passInterval(eventState)
      message = 'Class done. Your next class starts on its own.'
      if weekendProgress.enabled(eventState) then advanceWeekend(eventState) end
      return
    end
    eventState.reward = eventState.totalReward
  end
  local now = offers.clock()
  if venueNearby and eventState.venueArrivalDay and now then eventState.venueSessionDay = math.floor(now / 1440) end
  traffic.sync(venueEvent(eventState) ~= nil, venueEvent(eventState))
  message = 'Event complete. Prizes paid.'
end

function M.skipToMyGroup(eventId, key)
  if betting.pending() then return {ok = false, error = 'Finish this heat first.'} end
  local eventState = activeCareer() and event() or nil
  local status = skipToGroup.status(eventState, runner.status())
  if not status or not status.available then return {ok = false, error = status and status.reason or 'No registered run is available.'} end
  if eventId ~= eventState.id or key ~= status.key then return {ok = false, error = 'The running order changed. Review your next run again.'} end
  -- Only opponent heats may be interrupted. stop() invalidates their callbacks;
  -- their unrecorded results are then resolved by the normal numerical simulation.
  runner.stop()
  spectatorPass, eventState.inFlight = nil, nil
  runner.setWatching(false)
  updateSpectatorQualifying(eventState)
  parking.stop()
  local result = skipToGroup.run(eventState, completeEvent)
  autoNextAt, startBlockedReason = nil, nil
  if result.advanced then nextPassAt, nextPlayerCheckAt = clock, clock end
  message = result.ok and (result.noRuns and 'You have no remaining runs. Final qualifying results are available.'
    or 'Your next run is ready. Bring the registered car to its group space; check in first if inspection is due.') or result.error
  storage.save()
  gameplay_rawPois.clear()
  emit()
  if overhaul_career_saveSystem then saveStore.request('motorsport:skipToMyGroup') end
  return result
end

local function finishNpcRaces(eventState)
  if not eventState.bracket then
    simulation.qualify(eventState)
    if qualifying.nextEntrant(eventState.entrants or {}) then return false end
    eventState.bracket = bracket.build(qualifying.standings(eventState.entrants), definitions.qualifyingFieldSize(eventState))
    if not eventState.bracket then
      eventState.bracket = {rounds = {}, currentRound = 1, complete = true, noQualified = true}
      eventState.reward, eventState.rewardPaid = 0, true
    end
    eventState.phase = 'eliminations'
  end
  local _, complete = simulation.race(eventState)
  return complete
end

function M.finishSpectatorWeekend()
  local eventState = activeCareer() and event() or nil
  -- A second Finish Event (a stale button or Stop watching) changes and pays nothing.
  if playerStatus.finished(eventState, runner.isWatching()) and not betting.pending() then
    return {ok = true, eventComplete = true}
  end
  local status = resolvePlayerStatus(eventState, {pendingBet = betting.pending()})
  if not status or not status.finishEvent.allowed then
    return {ok = false, error = status and status.finishEvent.reason or 'No active event.'}
  end
  if eventState.phase == 'complete' then
    runner.stop()
    runner.setWatching(false)
    spectatorPass, eventState.inFlight, eventState.checkIn, eventState.venueArrivalDay, eventState.venueSessionDay = nil, nil, nil, nil, nil
    autoNextAt, startBlockedReason = nil, nil
    eventState.playerOutcomeAcknowledged = true
    clearArrivalChoice()
    parking.stop()
    eventDisplay.clear()
    syncDecor(nil)
    traffic.sync(false)
    gameplay_rawPois.clear()
    message = 'Your day at the event is done.'
    emit()
    storage.save()
    return {ok = true, eventComplete = true}
  end
  -- Check the entire event before stopping a live heat or changing saved results.
  local preview = deepcopy(eventState)
  weekend.sync(preview)
  for _, class in ipairs(preview.classes or {preview}) do
    if class.phase ~= 'complete' then
      if preview.formatVersion == 2 then weekend.activate(preview, class) end
      if not finishNpcRaces(preview) then return {ok = false, error = 'A player race still needs to be completed.'} end
    end
  end
  weekend.sync(eventState)
  runner.stop()
  runner.setWatching(false)
  spectatorPass, eventState.inFlight = nil, nil
  spectatorQualifying.clear(eventState)
  parking.stop()
  for _, class in ipairs(eventState.classes or {eventState}) do
    if class.phase ~= 'complete' then
      if eventState.formatVersion == 2 then weekend.activate(eventState, class) end
      finishNpcRaces(eventState)
      completeEvent(eventState)
      if class.phase ~= 'complete' then
        clearArrivalChoice()
        emit()
        return {ok = false, error = message}
      end
    end
  end
  eventState.phase = 'complete'
  eventState.checkIn, eventState.venueArrivalDay, eventState.venueSessionDay = nil, nil, nil
  eventState.playerOutcomeAcknowledged = true
  autoNextAt, startBlockedReason = nil, nil
  clearArrivalChoice()
  eventDisplay.clear()
  syncDecor(nil)
  traffic.sync(false)
  gameplay_rawPois.clear()
  message = 'Event complete. The races left were simulated.'
  emit()
  if overhaul_career_saveSystem then saveStore.request('motorsport:finishSpectatorWeekend') end
  return {ok = true, eventComplete = true}
end

local function simulateNpc(phase)
  if betting.pending() then return {ok = false, error = 'Finish this heat first.'} end
  if not M.isDevToolsEnabled() then return {ok = false, error = 'Developer key required.'} end
  local eventState = event()
  if not eventState or eventState.phase ~= phase then return {ok = false, error = 'This simulation is unavailable in the current event phase.'} end
  if runner.isWatching() or spectatorQualifying.context(eventState) then return {ok = false, error = 'Leave spectator qualifying before using developer simulation.'} end
  if weekendProgress.enabled(eventState) and phase == 'eliminations' then
    return {ok = false, error = 'All elimination heats run physically during this weekend.'}
  end
  if runner.status().phase ~= 'idle' then return {ok = false, error = 'Finish or cancel the active pass first.'} end
  local count, complete
  if phase == 'qualifying' then count = simulation.qualify(eventState)
  else count, complete = simulation.race(eventState) end
  autoNextAt, nextPassAt = nil, 0
  parking.stop()
  if complete then completeEvent(eventState)
  else message = count .. ' NPC ' .. (phase == 'qualifying' and 'qualifying results' or 'race results') .. ' simulated. Your next pass remains live.' end
  parking.update(eventState.phase ~= 'complete' and eventState or nil, 0)
  emit()
  if overhaul_career_saveSystem then saveStore.request('motorsport:simulateNpc') end
  return {ok = true}
end

function M.devSimulateQualifying() return simulateNpc('qualifying') end
function M.devSimulateRaces() return simulateNpc('eliminations') end

local function resultReceived(eventState, qualifyingEntrants, match, result)
  if event() ~= eventState then return end
  local resultEntrants = eventState.entrants
  local playerQualifier, playerEliminated = false, false
  for _, entrant in ipairs(qualifyingEntrants or {}) do if entrant.player then playerQualifier = true end end
  if eventState.formatVersion == 2 and eventState.activeClassId then
    local checked, err = classRules.applyResult(eventState.activeClassId, result, eventState.phase, eventState)
    if checked then result = checked else result.error = err end
  elseif eventState.formatVersion == 2 and eventState.phase == 'playerQualifying' and not playerQualifier then
    local checked, err = weekend.gradeNpcQualifying(eventState, result)
    if checked then result = checked else result.error = err end
  end
  eventState.inFlight = nil
  if result.error then
    betting.finish(eventState, match, result, false)
    message = result.error
    nextPassAt = clock + policy.passInterval(eventState)
    autoNextAt = nextPassAt
  elseif eventState.phase == 'playerQualifying' and playerQualifier then
    local outcome = weekend.recordPaired(eventState, result, qualifyingEntrants)
    message = outcome.message or (outcome.ok and 'Your best legal qualifying time is recorded in your declared class.' or outcome.error)
    if outcome.excluded then
      local refund = registration.refund(eventState, outcome.excluded, outcome.error)
      if not refund.ok then
        message = message .. ' ' .. refund.error
        eventState.pendingRefund = outcome.excluded.registrationId or outcome.excluded.id
      end
    end
    if not outcome.retry and not eventState.pendingRefund then
      if outcome.excluded then continueAfterRefund(eventState) else weekend.prepareNext(eventState) end
    end
    nextPassAt = clock + policy.passInterval(eventState)
    autoNextAt = eventState.phase ~= 'registration' and not eventState.pendingRefund and nextPassAt or nil
    if eventState.phase == 'registration' then interactions.routeRegistration(eventState) end
    gameplay_rawPois.clear()
  elseif qualifyingEntrants then
    for _, row in ipairs(result.rows) do
      local entrant = roster.find(qualifyingEntrants, row.entrantId)
      if entrant and not qualifying.isDone(entrant) then qualifying.record(entrant, row) end
    end
    message = 'Pass recorded. The best legal time sets the seed.'
    for _, entrant in ipairs(qualifyingEntrants) do
      if entrant.player and entrant.qualifying then
        message = entrant.qualifying.valid and string.format('Your time: %.3f s, recorded. Build the bracket when the field is ready.', entrant.qualifying.time)
          or ('Pass recorded as invalid: ' .. (entrant.qualifying.reason or 'no valid time') .. '.')
      end
    end
    nextPassAt = clock + policy.passInterval(eventState)
    local pair = qualifying.nextPair(eventState.entrants)
    if pair then autoNextAt = nextPassAt end
  else
    local previousRound = eventState.bracket.currentRound
    local ok, err = bracket.record(match, result)
    betting.finish(eventState, match, result, ok)
    message = ok and (match.complete and not match.winnerId and 'Both racers eliminated. No racer advances.' or 'Heat complete.') or err
    if ok and result.interference then
      local winner = roster.find(resultEntrants, result.winnerId)
      message = 'Lane foul. ' .. (winner and winner.name or 'The other racer') .. ' wins the heat.'
      toast(message, 'info', 10)
    end
    if ok then
      for _, entrant in ipairs(resultEntrants) do
        if entrant.player and (match.a == entrant.id or match.b == entrant.id) then
          playerEliminated = match.winnerId ~= entrant.id
          local outcome = bracket.playerOutcome(eventState.bracket, entrant.id)
          if outcome then toast((eventState.className or 'Drag event') .. ': ' .. outcome, 'info', 8) end
        end
      end
      local nextMatch = bracket.nextMatch(eventState.bracket)
      nextPassAt = clock + policy.passInterval(eventState)
      if not nextMatch then completeEvent(eventState)
      else
        autoNextAt = nextPassAt
        if weekendProgress.enabled(eventState) and previousRound ~= eventState.bracket.currentRound then
          weekend.sync(eventState)
          local advanced = advanceWeekend(eventState)
          if not advanced.ok then message = advanced.error end
        end
      end
    else
      nextPassAt = clock + policy.passInterval(eventState)
      autoNextAt = nextPassAt
    end
    for _, row in ipairs(result.rows or {}) do
      local entrant = roster.find(resultEntrants, row.entrantId)
      if entrant and entrant.player and row.reason and row.reason:find('Breakout', 1, true) then
        message = row.reason .. ' ' .. (ok and (result.winnerId == entrant.id and 'You win on the smaller breakout or your opponent\'s foul.' or 'Your opponent wins this heat.') or 'The heat will retry after the countdown.')
      end
    end
  end
  if eventState.formatVersion == 2 then weekend.sync(eventState) end
  runner.recordResult(result)
  local prepared, preparationError = prepareQualifying(eventState)
  if not prepared then
    message, startBlockedReason = preparationError, preparationError
    startBlocked = {reason = preparationError, code = 'qualifying_schedule_pending', kind = 'wait'}
  end
  parking.update(eventState.phase ~= 'complete' and weekendProgress.gate(eventState, claimedHeat(eventState)).allowed and eventState or nil, 0)
  if playerEliminated and (eventState.phase == 'complete' or weekendProgress.spectatorOnly(eventState)) then
    eventState.playerEliminated = true
    showSpectatorChoice()
  end
  emit()
  if overhaul_career_saveSystem then saveStore.request('motorsport:passResult') end
end

local function spectatorResult(eventState, view, result)
  local current = spectatorQualifying.context(eventState)
  if event() ~= eventState or not current or current.spectatorQualifyingKey ~= view.spectatorQualifyingKey then return end
  spectatorPass = nil
  eventState.inFlight = nil
  local recorded = spectatorQualifying.record(eventState, view, result)
  message = recorded.ok and 'Qualifying result recorded.' or recorded.error
  nextPassAt = clock + policy.passInterval(view)
  autoNextAt = nextPassAt
  emit()
  if overhaul_career_saveSystem then saveStore.request('motorsport:spectatorResult') end
end

function M.runNext()
  local eventState = event()
  if not activeCareer() or not eventState then return {ok = false, error = 'No active event.'} end
  if eventState.phase == 'complete' then return {ok = false, error = 'This event is complete.'} end
  if getCurrentLevelIdentifier() ~= eventState.level then return {ok = false, error = 'Return to ' .. _tr(eventState.stripName) .. ' for this event.'} end
  if runner.status().phase ~= 'idle' then return {ok = false, error = 'A pass is already active.'} end
  if eventState.phase == 'registration' then return {ok = false, error = 'Visit registration and enter your cars first.'} end
    local schedule = definitions.event(eventState).schedule
    if schedule and interactions.isNearVenue and not runner.isWatching()
      and not interactions.isNearVenue(eventState, schedule.venueActivityRadius) then
      return {ok = false, error = 'Return to the venue for your next race. Your entry is reserved.'}
    end
  local opening = weekendProgress.gate(eventState, claimedHeat(eventState))
  if not opening.allowed then return {ok = false, error = opening.message, reason = 'session_wait'} end
  if not weekendProgress.checkedIn(eventState) then return {ok = false, error = 'Check in at the venue for inspection before racing.', reason = 'check_in_required'} end
  if clock < nextPassAt then return {ok = false, error = 'Wait for the next pass countdown.'} end
  updateSpectatorQualifying(eventState)
  local prepared, preparationError = prepareQualifying(eventState)
  if not prepared then return holdPlayerStart(preparationError, 'qualifying_schedule_pending') end
  local savedEvent = eventState
  eventState = updateSpectatorQualifying(eventState, true)
  local gate = weekendProgress.gate(eventState, claimedHeat(eventState))
  if not gate.allowed then return {ok = false, error = gate.message, reason = 'session_wait'} end
  traffic.sync(true, eventState)
  parking.update(eventState, 0)
  local qualifyingEntrants, match, entrants
  if eventState.phase == 'playerQualifying' or eventState.phase == 'qualifying' then
    local watching = runner.isWatching() and (eventState.qualifyingCompression == true or eventState.spectatorQualifyingKey ~= nil)
    if parking.nextPair then qualifyingEntrants = parking.nextPair(eventState, watching)
    else qualifyingEntrants = qualifying.nextPair(eventState.entrants) end
    if not qualifyingEntrants then
      if watching then return holdPlayerStart('Your qualifying pass is next. Return to your car.', 'player_qualifying_required') end
      if qualifying.nextEntrant(eventState.entrants) then return holdPlayerStart('Wait for the current group to clear.', 'group_pending') end
      return {ok = false, error = 'Qualifying is complete. Build the bracket.'}
    end
    entrants = qualifyingEntrants
  elseif eventState.phase == 'eliminations' then
    local previousRound = eventState.bracket.currentRound
    match = bracket.nextMatch(eventState.bracket)
    if not match then completeEvent(eventState); emit(); return {ok = true} end
    if previousRound ~= eventState.bracket.currentRound then
      -- nextMatch advances a completed bracket. Its next round has a different
      -- opening time and may rotate to another class; old heat claims do not
      -- authorize dispatch in that new group.
      parking.stop()
      if weekendProgress.enabled(eventState) then
        weekend.sync(eventState)
        local advanced = advanceWeekend(eventState)
        if not advanced.ok then return {ok = false, error = advanced.error} end
        local nextGate = weekendProgress.gate(eventState)
        if not nextGate.allowed then return {ok = false, error = nextGate.message, reason = 'session_wait'} end
        if not weekendProgress.checkedIn(eventState) then
          return {ok = false, error = 'Check in at the venue for inspection before racing.', reason = 'check_in_required'}
        end
        -- Re-enter through the regular dispatch gate after the class transition.
        return M.runNext()
      end
      parking.update(eventState, 0)
    end
    if parking.nextPair then
      entrants = parking.nextPair(eventState)
      if not entrants then return holdPlayerStart('Wait for the current group to clear.', 'group_pending') end
      match = nil
      for _, candidate in ipairs(eventState.bracket.rounds[eventState.bracket.currentRound].matches) do
        if not candidate.winnerId and not candidate.complete and #entrants == 2
          and (candidate.a == entrants[1].id and candidate.b == entrants[2].id
            or candidate.a == entrants[2].id and candidate.b == entrants[1].id) then match = candidate; break end
      end
      if not match then return holdPlayerStart('The next group is preparing its bracket heat.', 'group_pending') end
    else entrants = {roster.find(eventState.entrants, match.a), roster.find(eventState.entrants, match.b)} end
  else return {ok = false, error = 'This event is complete.'} end
  local ready, readinessReason = parking.isHeatReady(entrants)
  if not ready then return holdPlayerStart(readinessReason, 'spawn_pending') end
  for _, entrant in ipairs(entrants) do
    if entrant.player and entrant.inventoryId then
      if not weekendProgress.inspected(savedEvent, entrant) then
        return holdPlayerStart('Bring this car to check-in for today\'s inspection.', 'inspection_required')
      end
      local inventory = overhaul_career_garage_inventory
      local id = inventory and inventory.getVehicleIdFromInventoryId(entrant.inventoryId)
      if not id or id ~= be:getPlayerVehicleID(0) or gameplay_walk and gameplay_walk.isWalking() then
        local spot = parking.getPlayerSpot(eventState)
        return holdPlayerStart('Enter your registered car and ' .. (spot and ('bring it to ' .. parking.spotLabel(spot) .. '.') or 'stop when you are ready.'), 'registered_car_required')
      end
      lastInventoryId = entrant.inventoryId
    end
    if entrant.player and not roster.matchesVehicle(entrant, be:getPlayerVehicle(0)) then
      local reason, code = roster.mismatchReason(entrant, be:getPlayerVehicle(0))
      return holdPlayerStart(reason, code, entrant, be:getPlayerVehicle(0))
    end
  end
  for _, entrant in ipairs(entrants) do
    if entrant.player and not parking.isPlayerReady(eventState) then
      local spot = parking.getPlayerSpot(eventState)
      if spot then
        parking.routePlayer(eventState)
        return holdPlayerStart('Stop in ' .. parking.spotLabel(spot) .. ' to start your pass.', 'group_parking_required')
      end
      return holdPlayerStart('Stop the car to start your pass.', 'player_moving')
    end
  end
  local ok, err = runner.start({stripId = eventState.stripId, stripName = _tr(eventState.stripName), stripFile = eventState.stripFile, entrants = entrants,
    qualifying = qualifyingEntrants ~= nil},
    function(result)
      if eventState.spectatorQualifyingKey then spectatorResult(savedEvent, eventState, result)
      else resultReceived(eventState, qualifyingEntrants, match, result) end
    end)
  if not ok then return {ok = false, error = err} end
  if eventState.spectatorQualifyingKey then
    local ids = {}
    for _, entrant in ipairs(entrants) do ids[#ids + 1] = entrant.id end
    spectatorPass = {key = eventState.spectatorQualifyingKey, ids = ids}
  end
  startBlockedReason = nil
  savedEvent.inFlight = qualifyingEntrants and qualifyingEntrants[1].id or match.id
  betting.open(eventState, match, entrants, runner.isWatching())
  message = qualifyingEntrants and ('Qualifying: ' .. entrants[1].name .. (entrants[2] and ' vs ' .. entrants[2].name or '')) or 'Next elimination heat ready.'
  autoNextAt = nil
  emit()
  return {ok = true}
end

function M.buildBracket()
  local eventState = event()
  if spectatorQualifying.context(eventState) then return {ok = false, error = 'Finish spectator qualifying before building the bracket.'} end
  if not activeCareer() or not eventState or eventState.phase ~= 'qualifying' or runner.status().phase ~= 'idle' then
    return {ok = false, error = 'Finish qualifying first.'}
  end
  if qualifying.nextEntrant(eventState.entrants) then return {ok = false, error = 'Every entrant must complete a qualifying attempt.'} end
  if weekendProgress.enabled(eventState) then
    local advanced = advanceWeekend(eventState)
    if not advanced.ok then return advanced end
    autoNextAt = math.max(clock, nextPassAt)
    emit()
    return {ok = true}
  end
  if eventState.formatVersion == 2 and weekend.nextPlayer(eventState) then
    weekend.sync(eventState)
    weekend.prepareNext(eventState)
    parking.stop()
    autoNextAt = math.max(clock, nextPassAt)
    message = 'Qualifying done for this class. Your next class qualifies on its own.'
    emit()
    return {ok = true}
  end
  local built, err = bracket.build(qualifying.standings(eventState.entrants), definitions.qualifyingFieldSize(eventState))
  if not built then
    if eventState.formatVersion ~= 2 then return {ok = false, error = err} end
    eventState.bracket, eventState.reward, eventState.rewardPaid = {rounds = {}, currentRound = 1, complete = true, noQualified = true}, 0, true
    completeEvent(eventState)
    message = 'Nobody qualified. This class ends with no winner or prizes.'
    emit()
    return {ok = true}
  end
  eventState.bracket, eventState.phase = built, 'eliminations'
  if eventState.formatVersion == 2 then weekend.sync(eventState) end
  local match = bracket.nextMatch(built)
  if not match then
    completeEvent(eventState)
    emit()
    return {ok = true}
  end
  autoNextAt = math.max(clock, nextPassAt)
  message = 'Bracket set. NPC heats run on their own before yours each round.'
  emit()
  return {ok = true}
end

function M.cancelPass()
  if betting.pending() then return {ok = false, error = 'Finish this heat first.'} end
  if not activeCareer() or not event() then return {ok = false, error = 'No active event.'} end
  runner.stop()
  spectatorPass = nil
  event().inFlight = nil
  nextPassAt = clock + policy.passInterval(event())
  autoNextAt = nextPassAt
  message = 'Pass canceled. Nothing was recorded, and it will run again.'
  emit()
  return {ok = true}
end

function M.devCancelEvent()
  if betting.pending() then return {ok = false, error = 'Finish this heat first.'} end
  if not M.isDevToolsEnabled() then return {ok = false, error = 'Developer key required.'} end
  runner.stop()
  spectatorPass = nil
  spectatorQualifying.clear(event())
  eventDisplay.clear()
  parking.stop()
  traffic.sync(false)
  autoNextAt, startBlockedReason, storage.get().event = nil, nil, nil
  message = 'Event canceled.'
  emit()
  return {ok = true}
end

function M.watchPass()
  if not activeCareer() or not event() then return {ok = false, error = 'No active event.'} end
  if not M.isDragDispatchActive() and not (event().phase == 'complete' and venueEvent(event())) then return {ok = false, error = 'Check in when today\'s session is available before spectating.'} end
  if not gameplay_walk or not gameplay_walk.isWalking() then return {ok = false, error = 'Walk into the spectator area to watch.'} end
  local ok, err = runner.setWatching(true)
  return {ok = ok, error = err}
end

function M.stopWatching()
  if betting.pending() then return {ok = false, error = 'Wait for your bet to settle, then stop watching.'} end
  local eventState = activeCareer() and event() or nil
  if eventState and eventState.phase == 'complete' then return M.finishSpectatorWeekend() end
  local ok, err = runner.setWatching(false)
  if eventState then updateSpectatorQualifying(eventState) end
  emit()
  return {ok = ok, error = err}
end

function M.returnToCar()
  if betting.pending() then return {ok = false, error = 'Wait for your bet to settle, then stop watching.'} end
  M.stopWatching()
  local inventoryId = lastInventoryId
  for _, entrant in ipairs(event() and event().entrants or {}) do
    if entrant.player and entrant.inventoryId then inventoryId = entrant.inventoryId; break end
  end
  if inventoryId and overhaul_career_garage_inventory then
    overhaul_career_garage_inventory.enterVehicle(inventoryId, nil, function()
      local eventState = event()
      if eventState then parking.routePlayer(eventState) end
    end)
  end
  return {ok = true}
end

function M.cycleSpectatorCamera()
  if not runner.isWatching() or not runner.cycleSpectatorCamera then return {ok = false, error = 'Enter spectator mode first.'} end
  local ok, state = runner.cycleSpectatorCamera()
  return {ok = ok, error = not ok and state or nil}
end

function M.placeSpectatorBet(marketId, entrantId, stake)
  if not activeCareer() then return {ok = false, error = 'Career required.', retryable = true} end
  return betting.place(marketId, entrantId, stake, runner.status(), runner.isWatching())
end

-- Opening the slip pauses the heat until the player bets or hides it; the slip passes its own name so
-- only it can close itself.
function M.openSpectatorBetSlip(marketId, slipName)
  if not activeCareer() then return {ok = false, error = 'Career required.'} end
  return betting.openSlip(marketId, runner.status(), runner.isWatching(), slipName)
end
function M.closeSpectatorBetSlip(slipName)
  betting.closeSlip(slipName)
  return {ok = true}
end
-- The stock pause stack is cleared when the UI starts, and the slip it was holding is gone with it.
function M.onUIInitialised() betting.closeSlip() end

function M.getSpectatorState()
  local runtime = runner.status()
  local eventState = activeCareer() and event() or nil
  local playerHeat = false
  for _, racer in ipairs(runtime.racers or {}) do if racer.player then playerHeat = true end end
  local camera = runner.spectatorCameraState and runner.spectatorCameraState() or {}
  local outcomeChoice = spectatorArrivalChoice and needsOutcomeChoice(eventState)
  local status = resolvePlayerStatus(eventState, runtime)
  local outcome = status and status.outcome
  local detail = status and status.step and status.step.text
  -- The overlay renders Finish Event guidance separately from outcome facts.
  if outcome then detail = outcome.reason end
  if outcome then
    if outcome.id == 'didNotQualify' then
      detail = (outcome.bestTime and string.format('Best %.3f s. ', outcome.bestTime) or 'No legal qualifying time. ')
        .. (outcome.cutTime and string.format('The cut was %.3f s.', outcome.cutTime) or '')
    elseif outcome.id == 'eliminated' and outcome.lostTo then
      -- The prompt's title names the round.
      detail = 'Lost to ' .. outcome.lostTo .. '.'
    end
    if (outcome.reward or 0) > 0 then
      local reward = string.format('%.0f', outcome.reward):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
      detail = (detail or '') .. ' Payout earned $' .. reward .. '.'
    end
  end
  local racing = eventState and (spectatorQualifying.context(eventState) or eventState)
  local names, byId = {}, {}
  for _, entrant in ipairs(racing and racing.entrants or {}) do byId[entrant.id] = entrant.name or entrant.model end
  for _, racer in ipairs(runtime.racers or {}) do
    if byId[racer.entrantId] then names[#names + 1] = byId[racer.entrantId] end
  end
  local round = racing and playerStatus.roundContext(racing)
  local roundName = round and round.name or racing and (racing.phase == 'qualifying' or racing.phase == 'playerQualifying') and 'Qualifying'
  return {playerStatus = status, eventName = eventState and eventState.name, outcomeDetail = outcomeChoice and detail or nil,
    nowRacing = #names > 0 and {names = names, className = racing.className, roundName = roundName} or nil,
    seeResults = eventState ~= nil and eventState.phase == 'complete' and not betting.pending(),
    visible = eventState ~= nil and runner.isWatching(),
    betting = activeCareer() and betting.view(runtime, spectatorQualifying.context(eventState) or eventState) or nil,
    outcomeChoice = outcomeChoice, outcomeTitle = outcomeChoice and status and status.step.title or nil,
    arrivalChoice = spectatorArrivalChoice, canFinishWeekend = status ~= nil and status.finishEvent.allowed,
    watching = runner.isWatching(), phase = runtime.phase, playerHeat = playerHeat,
    eventComplete = eventState ~= nil and eventState.phase == 'complete',
    sessionComplete = eventState ~= nil and (eventState.phase == 'complete' or not weekendProgress.gate(eventState, claimedHeat(eventState)).allowed),
    cameraCount = camera.cameraCount, cameraIndex = camera.cameraIndex, cameraName = camera.cameraName}
end

function M.onUpdate(dtReal, dtSim)
  -- A UI reload can lose its bridge callback while an arrival holds simulation.
  updateSpectatorActivitySync(dtReal)
  betting.watchSlip(dtReal, runner.isWatching())
  if spectatorArrivalChoice then return end
  eventDecor.update()
  if not activeCareer() then
    parking.update(nil, dtSim)
    traffic.sync(false)
    eventDisplay.clear()
    syncDecor(nil)
    return
  end
  if spectatorChoicePending then
    local player = be:getPlayerVehicle(0)
    local stopped = player and player:getVelocity():length() <= .5
    spectatorStoppedSeconds = stopped and spectatorStoppedSeconds + math.max(0, dtReal or 0, dtSim or 0) or 0
    if spectatorStoppedSeconds >= 1 then
      spectatorChoicePending = false
      setArrivalChoice(true)
      if simTimeAuthority then simTimeAuthority.pushPauseRequest('motorsportArrival') end
      emit()
      return
    end
  end
  clock = clock + dtSim
  runner.onUpdate(dtSim)
  local eventState = activeCareer() and event() or nil
  calendarPoll = calendarPoll + math.max(0, dtSim)
  if calendarPoll >= 1 then
    calendarPoll = calendarPoll % 1
    local schedule = eventState and definitions.event(eventState).schedule
    venueNearby = not schedule or runner.status().phase ~= 'idle' or runner.isWatching() or not interactions.isNearVenue
      or interactions.isNearVenue(eventState, schedule.venueActivityRadius)
    if not venueNearby and runner.status().phase == 'idle' then parking.stop() end
    local previous = offerCacheKey
    calendarState()
    if previous ~= offerCacheKey then guihooks.trigger('motorsportEventsUpdated', M.getState()) end
    if eventState and eventState.phase ~= 'complete' and eventState.phase ~= 'registration' and not eventState.pendingRefund
      and runner.status().phase == 'idle' and not claimedHeat(eventState)
      and (not weekendProgress.checkedIn(eventState) or not venueNearby or eventState.level ~= getCurrentLevelIdentifier()) then
      local result = background.step(eventState, 4)
      if result.changed or result.complete then
        weekend.sync(eventState)
        if result.complete and eventState.phase == 'eliminations' and eventState.bracket and not bracket.nextMatch(eventState.bracket) then completeEvent(eventState)
        elseif result.complete then weekendProgress.advance(eventState) end
        storage.save()
      end
    end
    if not spectatorChoicePending and needsOutcomeChoice(eventState) then
      showSpectatorChoice()
      emit()
    end
  end
  local active = eventState and eventState.phase ~= 'complete' and eventState.level == getCurrentLevelIdentifier()
    and (venueNearby or runner.status().phase ~= 'idle')
  if active and weekendProgress.checkedIn(eventState) then updateSpectatorQualifying(eventState) end
  interactions.update(eventState and eventState.level == getCurrentLevelIdentifier() and eventState or nil, dtSim, active or venueEvent(eventState) ~= nil)
  if active and eventState.bracket and not eventState.bracket.playerId then
    for _, entrant in ipairs(eventState.entrants) do if entrant.player and entrant.seed then eventState.bracket.playerId = entrant.id; break end end
  end
  if active and weekendProgress.checkedIn(eventState) and not eventState.pendingRefund and runner.status().phase == 'idle'
    and weekendProgress.gate(eventState, claimedHeat(eventState)).allowed then
    local prepared, preparationError = prepareQualifying(eventState)
    if not prepared then
      traffic.sync(weekendProgress.gate(eventState, claimedHeat(eventState)).allowed, eventState)
      if not claimedHeat(eventState) then parking.stop() end
      local hold = {reason = preparationError, code = 'qualifying_schedule_pending', kind = 'wait'}
      eventDisplay.update(eventState, runner.status(), preparationError, 0, dtSim, preparationError, paddockState(eventState, runner.status()), weekendProgress.session(eventState), deferredDisplayStatus(eventState, runner.status(), nil, hold))
      return
    end
  end
  local view = active and weekendProgress.checkedIn(eventState) and updateSpectatorQualifying(eventState, true) or eventState
  local runtime = runner.status()
  if betting.isOpen() then betting.update(dtReal, runtime) end
  local gate = active and weekendProgress.gate(view, claimedHeat(eventState)) or {allowed = false}
  local session = eventState and weekendProgress.session(view, claimedHeat(eventState)) or nil
  local checkedIn = active and weekendProgress.checkedIn(eventState)
  if active and runtime.phase == 'idle' and eventState.checkInVersion == 1 and eventState.checkIn and not checkedIn then
    eventState.checkIn = nil
    eventState.venueArrivalDay = nil
    checkedIn = false
    parking.stop()
    eventDisplay.clear()
    autoNextAt, startBlockedReason = nil, nil
    message = 'Day done. Check in again next day for inspection.'
    local opening = weekendProgress.gate(eventState)
    if opening.realTime and not opening.allowed then message = 'Day done. ' .. opening.message end
    if weekendProgress.canAdvanceDay(eventState) then message = "Day done. Skip ahead in the Motorsport Events app when you're ready." end
    toast(message, 'info', 10)
    emit()
    session = weekendProgress.session(view)
  end
  local venue = venueEvent(eventState)
  traffic.sync(venue ~= nil, venue)
  syncDecor(venue)
  parking.update(active and checkedIn and gate.allowed and not eventState.pendingRefund and view.phase ~= 'registration' and view or nil, dtSim, runtime.playerPass, dtReal)
  if active and eventState.pendingRefund then
    autoNextAt = nil
    if clock >= nextPlayerCheckAt then
      nextPlayerCheckAt = clock + 5
      for _, row in ipairs(eventState.registrations or {}) do
        if (row.registrationId or row.id) == eventState.pendingRefund then
          local result = registration.refund(eventState, row, row.classError)
          if result.ok then
            eventState.pendingRefund = nil
            continueAfterRefund(eventState)
            nextPassAt = clock + policy.passInterval(eventState)
            autoNextAt = eventState.phase ~= 'registration' and nextPassAt or nil
            message = 'Entry refunded. The event goes on.'
            if eventState.phase == 'registration' then interactions.routeRegistration(eventState) end
          else message = result.error end
          emit()
          break
        end
      end
    end
    eventDisplay.update(eventState, runner.status(), message, 0, dtSim, startBlockedReason, paddockState(eventState, runner.status()), session, deferredDisplayStatus(eventState, runner.status(), session))
    return
  end
  if session then
    local key = table.concat({eventState.id, session.day, session.stage, tostring(session.waiting), tostring(session.clockReady), tostring(view.spectatorQualifyingKey or view.activeRegistrationId or view.activeClassId)}, ':')
    if key ~= lastSessionKey then lastSessionKey = key; emit() end
  end
  if active and not checkedIn and runtime.phase == 'idle' then
    autoNextAt, startBlockedReason = nil, nil
    eventDisplay.update(view, runtime, message, 0, dtSim, nil, paddockState(view, runtime), session, deferredDisplayStatus(view, runtime, session))
    return
  end
  if active and not gate.allowed then
    autoNextAt, startBlockedReason, sessionWasWaiting = nil, nil, true
    eventDisplay.update(view, runtime, message, 0, dtSim, nil, paddockState(view, runtime), session, deferredDisplayStatus(view, runtime, session))
    return
  end
  if active and sessionWasWaiting then
    nextPassAt, autoNextAt, nextPlayerCheckAt, sessionWasWaiting = clock, clock, clock, false
  end
  if active and autoNextAt and clock >= autoNextAt then
    autoNextAt = nil
    local result = M.runNext()
    if not result.ok then message = result.error; nextPlayerCheckAt = clock + 5; emit() end
  end
  if active and eventState.phase ~= 'registration' and runner.status().phase == 'idle' and not autoNextAt and clock >= nextPassAt and clock >= nextPlayerCheckAt then
    nextPlayerCheckAt = clock + 5
    local result
    if not view.spectatorQualifyingKey and eventState.phase == 'qualifying' and not qualifying.nextPair(eventState.entrants) then result = M.buildBracket()
    else result = M.runNext() end
    if not result.ok and message ~= result.error then message = result.error; emit() end
  end
  local displayRuntime = runner.status()
  local displayHold = startBlockedReason
  if displayHold and startBlocked and startBlocked.reason == displayHold and startBlocked.code == 'configuration_changed' then
    displayHold = partsHoldMessage(startBlocked.partChanges)
  end
  local reminder = eventState and (eventState.phase == 'registration' or session and (session.waiting or session.checkInRequired))
  local displayEvent = (active or venue or reminder) and view or nil
  eventDisplay.update(displayEvent, displayRuntime, message, nextPassAt - clock, dtSim, displayHold,
    paddockState(view, displayRuntime), session, deferredDisplayStatus(displayEvent, displayRuntime, session))
end

local function loadEvent()
  offerCacheKey, offerCache, calendarPoll, venueNearby = nil, nil, 0, true
  spectatorPass = nil
  lastSessionKey, sessionWasWaiting = nil, false
  -- The weekend lives in the career save, and resuming it needs career owners such as payment.
  -- Worlds load before (or without) a career; career activation calls loadEvent again.
  if not activeCareer() then return end
  storage.load()
  betting.load(storage.get())
  local eventState = event()
  -- Repair old snapshot labels before HUD, spectator and finance consumers see them.
  if eventState and eventState.stripName then
    local stripName = _tr(eventState.stripName)
    if stripName ~= eventState.stripName then
      local pattern = eventState.stripName:gsub('(%W)', '%%%1')
      eventState.name = eventState.name and eventState.name:gsub(pattern, function() return stripName end)
      eventState.stripName = stripName
    end
  end
  if eventState and eventState.formatVersion == 2 then
    definitions.restoreLegacySnapshot(eventState)
    if eventState.spectatorQualifying and eventState.spectatorQualifying.job then
      eventState.inFlight = nil
      spectatorQualifying.exit(eventState, {})
      spectatorQualifying.reseed(eventState)
      spectatorQualifying.clear(eventState)
    end
    rewards.migrate(eventState)
    weekend.resume(eventState)
    local migrated = qualifyingSchedule.migrate(eventState)
    if not migrated.ok then message, startBlockedReason = migrated.error, migrated.error end
    weekendProgress.initialize(eventState)
    if eventState.checkInVersion == 1 then
      -- A participant loading inside the venue does not cross an entrance trigger.
      -- Keep their arrival; venue distance and the session day still gate activation.
      if not weekendProgress.checkedIn(eventState) then eventState.venueArrivalDay = nil end
      if eventState.checkIn and eventState.checkIn.spectatorOnly then eventState.checkIn, eventState.venueArrivalDay = nil, nil end
    end
    if not claimedHeat(eventState) then
      local resumed = weekendProgress.resume(eventState)
      if not resumed.ok then message, startBlockedReason = resumed.error, resumed.error end
    end
    registration.begin(eventState)
    weekendProgress.completeRegistrationInspection(eventState)
    local schedule = definitions.event(eventState).schedule
    if schedule and interactions.isNearVenue then venueNearby = interactions.isNearVenue(eventState, schedule.venueActivityRadius) end
    storage.save()
  end
end
local function initInteractions()
  interactions.init({activeEvent = function() return activeCareer() and event() end,
    arrive = function() M.arrive() end,
    spectate = function() M.watchPass() end,
    openRegistration = function()
      local eventState = event()
      if eventState then guihooks.trigger('MotorsportRegistrationOpen', M.getState()) end
    end})
end
function M.onExtensionLoaded()
  loadEvent(); runner.init(); missionMarkers.init()
  syncDecor(activeCareer() and venueEvent(event()) or nil)
  initInteractions()
  M.requestSpectatorActivity()
end
function M.onBeamNGTrigger(data) interactions.onBeamNGTrigger(data) end
function M.onEditorActivated() eventDecor.invalidate(); decorSynced = false; syncDecor(activeCareer() and venueEvent(event()) or nil) end
M.onEditorDeactivated = M.onEditorActivated
function M.onVehicleSwitched(oldId)
  local id = overhaul_career_garage_inventory and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(oldId)
  if id then lastInventoryId = id end
end
function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  local eventState = activeCareer() and event() or nil
  if not eventState or eventState.phase == 'complete' or eventState.level ~= levelIdentifier then return end
  interactions.getPois(eventState, elements)
  local spot = parking.getPlayerSpot(eventState)
  if spot then
    elements[#elements + 1] = {id = 'motorsportPlayerGrid', data = {type = 'motorsportPlayerGrid', name = parking.spotLabel(spot)},
      markerInfo = {parkingMarker = {pos = spot.pos, rot = spot.rot, scl = spot.scl, path = 'motorsportPlayerGrid', icon = 'poi_parking_rect', focus = false}},
      pos = spot.pos, radius = 4}
  end
end
function M.onSerialize()
  return {waitSeconds = math.max(0, nextPassAt - clock), autoNextSeconds = autoNextAt and math.max(0, autoNextAt - clock),
    traffic = traffic.onSerialize and traffic.onSerialize()}
end
function M.onDeserialized(data)
  nextPassAt = clock + (data.waitSeconds or 0)
  autoNextAt = data.autoNextSeconds and clock + data.autoNextSeconds or nil
  if data.traffic and traffic.onDeserialized then traffic.onDeserialized(data.traffic) end
end
function M.onOverhaulModulesActivated() clearArrivalChoice(); eventDisplay.clear(); runner.stop(); parking.stop(); traffic.sync(false); loadEvent(); syncDecor(venueEvent(event())); autoNextAt = nil; initInteractions() end
function M.onOverhaulSaveCurrentProfile(path, _, writer) storage.save(path, writer) end
function M.onDragClear() runner.onDragClear() end
function M.onClientEndMission() spectatorActivitySyncPending = false; betting.interrupt(); runner.setWatching(false); clearArrivalChoice(); eventDisplay.clear(); runner.stop(); parking.stop(); traffic.sync(false); interactions.shutdown(); shutdownDecor(); autoNextAt = nil end
function M.onExtensionUnloaded() spectatorActivitySyncPending = false; betting.interrupt(); clearArrivalChoice(); eventDisplay.clear(); runner.shutdown(); parking.stop(); traffic.sync(false); missionMarkers.shutdown(); interactions.shutdown(); shutdownDecor(); autoNextAt = nil end
M.onOverhaulModeStopped = M.onClientEndMission

return M
