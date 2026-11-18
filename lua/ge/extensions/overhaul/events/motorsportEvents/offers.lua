-- Owns league offer rotation and cooldown state.
-- eventClock.lua supplies real time; definitions.lua supplies rotation rules; storage.lua persists the supplied state.
local M = {}
local definitions = require('overhaul/events/motorsportEvents/definitions')
local catalog = require('overhaul/events/motorsportEvents/drag/catalog')
local venues = require('overhaul/events/motorsportEvents/drag/venues')
local rewards = require('overhaul/events/motorsportEvents/rewards')
local eventClock = require('overhaul/events/motorsportEvents/eventClock')

local function position(r, today, frozen, count)
  return (r.position - 1 + (frozen and 0 or math.max(0, today - r.anchorDay))) % count + 1
end

local function defer(r, today)
  r.availableAt, r.availableDay = eventClock.now() + eventClock.cooldown, today + 1
  r.offerExpiresAt = nil
  r.offerSerial = (r.offerSerial or 0) + 1
  r.anchorDay = today
end

function M.clock()
  local weather = overhaul_world_weather
  if not weather or not weather.getWorldMinutes then return nil end
  if weather.getCalendarState then
    local ok, state = pcall(weather.getCalendarState)
    if not ok or type(state) ~= 'table' or state.ready ~= true then return nil end
  end
  local ok, now = pcall(weather.getWorldMinutes)
  if not ok then return nil end
  if type(now) ~= 'number' or now ~= now or now < 0 or now == math.huge then return nil end
  local cycle = weather.getDayNightCycle and weather.getDayNightCycle()
  return math.floor(now), cycle and cycle.play == false or false
end

function M.sync(state, eventState)
  local now, frozen = M.clock()
  local config = definitions.data().rotation
  if not now or not config or not config.enabled then return false end
  local today, changed = math.floor(now / 1440), false
  local r = state.rotation
  if not r then
    r = {version = 1, anchorDay = today, highestDay = today, position = 1, clockFrozen = frozen}
    state.rotation, changed = r, true
  end
  local effective = math.max(today, r.highestDay)
  if effective ~= r.highestDay then r.highestDay, changed = effective, true end
  local active = eventState and (eventState.phase ~= 'complete' or eventState.venueSessionDay == today)
  if r.clockFrozen ~= frozen then
    if not r.activeEventId and not r.availableAt then
      r.position = position(r, effective, r.clockFrozen == true, #config.leagueIds)
      r.anchorDay, r.offerExpiresAt = effective, nil
    end
    r.clockFrozen, changed = frozen, true
  end
  if active then
    if not r.activeEventId then
      r.position = position(r, effective, frozen, #config.leagueIds)
      r.anchorDay, r.activeEventId, changed = effective, eventState.id, true
      r.offerExpiresAt, r.availableAt, r.availableDay = nil, nil, nil
    end
  elseif r.activeEventId then
    r.position = r.position % #config.leagueIds + 1
    r.activeEventId, changed = nil, true
    defer(r, effective)
  end
  if not active then
    if r.availableAt then
      local ready = frozen and eventClock.now() >= r.availableAt or not frozen and effective >= r.availableDay
      if not ready then return changed end
      r.availableAt, r.availableDay, r.anchorDay, changed = nil, nil, effective, true
    end
    if frozen then
      local realNow = eventClock.now()
      if not r.offerExpiresAt then r.offerExpiresAt, changed = realNow + eventClock.offerLifetime, true end
      if realNow >= r.offerExpiresAt then
        local expired = math.floor((realNow - r.offerExpiresAt) / eventClock.offerLifetime) + 1
        r.position = (r.position - 1 + expired) % #config.leagueIds + 1
        r.offerSerial = (r.offerSerial or 0) + expired
        r.offerExpiresAt, changed = r.offerExpiresAt + expired * eventClock.offerLifetime, true
      end
    elseif r.offerExpiresAt then r.offerExpiresAt, changed = nil, true end
  end
  return changed
end

function M.view(state, eventState, level)
  local now, frozen = M.clock()
  local config = definitions.data().rotation
  local active = eventState and eventState.phase ~= 'complete'
  local view = {ready = now ~= nil, clockFrozen = frozen, rotationPaused = active == true,
    canAdvanceOffer = false}
  if not now then view.message = 'Waiting for the career calendar.'; return view end
  if active then view.message = 'League rotation is paused until this event finishes or you withdraw.'; return view end
  if not config or not config.enabled then view.message = 'Daily events are unavailable.'; return view end
  local r = state.rotation
  if not r then return view end
  local today = math.max(math.floor(now / 1440), r.highestDay)
  local offerPosition = position(r, today, frozen, #config.leagueIds)
  local leagueId = config.leagueIds[offerPosition]
  view.id = table.concat({level or '', today, leagueId, r.offerSerial or 0, tostring(frozen)}, ':')
  view.nextOfferWorldMinute = (r.availableDay or today + 1) * 1440 + config.offerMinuteOfDay
  view.canAdvanceOffer = not frozen and not (overhaul_world_weather.isExternalOverrideActive and overhaul_world_weather.isExternalOverrideActive())
    and type(overhaul_world_weather.sleepTo) == 'function'
  if r.availableAt then
    view.cooldown = true
    view.remainingSeconds = frozen and math.max(0, r.availableAt - eventClock.now()) or nil
    view.message = frozen and ('Next offer in ' .. math.ceil(view.remainingSeconds / 60) .. ' real minutes.')
      or 'The next league offer arrives on the next career day.'
    return view
  end
  local league = definitions.league(leagueId)
  local snapshot = definitions.snapshot(config.eventId, level)
  local definition = snapshot and snapshot.eventDefinition
  local strip
  if definition then
    for _, candidate in ipairs(venues.list(level)) do
      if not definition.stripId or candidate.strip.id == definition.stripId then strip = candidate; break end
    end
  end
  local offer = {id = view.id, leagueId = leagueId,
    leagueName = league.name, fee = league.fee, dayIndex = today, definitionId = config.eventId, classes = {},
    stages = definition and definition.stages, prizes = definition and rewards.prizes(snapshot, leagueId),
    startWorldMinute = today * 1440 + (definition and definition.stages.qualifying.minuteOfDay or 600),
    venueName = strip and _tr(strip.strip.name or strip.strip.id), stripId = strip and strip.strip.id,
    available = false}
  local scope = snapshot or {}
  scope.eventDefinition = definition
  for _, class in ipairs(catalog.listClasses(leagueId)) do
    if definition and definitions.accepts(class, scope) then
      offer.classes[#offer.classes + 1] = {id = class.id, name = class.name,
        requirementsText = class.requirementsText, indexSeconds = class.indexSeconds,
        descriptor = class.descriptor, description = class.description, classRulesText = class.classRulesText,
        cageText = class.cageText, cageExceptionsText = class.cageExceptionsText}
      offer.available = true
    end
  end
  if not strip then offer.available, offer.unavailableReason = false, 'This map has no supported venue for this event.'
  elseif not offer.available then offer.unavailableReason = 'No classes are scheduled for this event.' end
  view.offer = offer
  view.expiresInSeconds = frozen and math.max(0, (r.offerExpiresAt or eventClock.now()) - eventClock.now()) or nil
  view.message = frozen and 'Offers expire after 60 real minutes. Declining starts a 30-minute wait.'
    or 'Accept an event or decline and wait for the next career day.'
  return view
end

function M.decline(state)
  local now, frozen = M.clock()
  local r, config = state.rotation, definitions.data().rotation
  local today = math.max(math.floor(now / 1440), r.highestDay)
  r.position = position(r, today, frozen, #config.leagueIds) % #config.leagueIds + 1
  defer(r, today)
  return {ok = true}
end

-- Developer override: today's offer becomes this league, with any decline cooldown cleared.
-- The rotation carries on from the forced league on the following days.
function M.forceLeague(state, leagueId)
  local now = M.clock()
  local config = definitions.data().rotation
  if not now or not config or not config.enabled then return {ok = false, error = 'Daily events are unavailable.'} end
  local index
  for i, id in ipairs(config.leagueIds) do if id == leagueId then index = i end end
  if not index then return {ok = false, error = 'Unknown league: ' .. tostring(leagueId)} end
  local r = state.rotation
  if not r then return {ok = false, error = 'Waiting for the career calendar.'} end
  if r.activeEventId then return {ok = false, error = 'League rotation is paused until the current event finishes.'} end
  r.position, r.anchorDay = index, math.max(math.floor(now / 1440), r.highestDay)
  r.availableAt, r.availableDay, r.offerExpiresAt = nil, nil, nil
  r.offerSerial = (r.offerSerial or 0) + 1
  return {ok = true}
end

function M.advance(target)
  local now = M.clock()
  local weather = overhaul_world_weather
  if not now or not target or target <= now then return {ok = false, error = 'The scheduled time is already available.'} end
  if not weather.sleepTo or weather.isExternalOverrideActive and weather.isExternalOverrideActive() then
    return {ok = false, error = 'The career clock cannot be advanced while externally controlled.'}
  end
  -- Bound jumps and use the owner of the world clock, preserving its play preference.
  if target - now > 1440 * 366 then return {ok = false, error = 'The requested calendar jump is too large.'} end
  for _ = 1, 367 do
    now = M.clock()
    if now >= target then return {ok = true} end
    local step = math.min(target, now + 1440)
    if weather.sleepTo((step % 1440 / 1440 + .5) % 1) ~= true then
      return {ok = false, error = 'The career calendar could not advance.'}
    end
    local updated = M.clock()
    if not updated or updated <= now then return {ok = false, error = 'The career clock did not advance.'} end
  end
  return {ok = false, error = 'Calendar advance did not finish.'}
end
return M
