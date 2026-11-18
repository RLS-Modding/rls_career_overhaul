-- Owns event prize calculation and settlement flags.
-- drag/placings.lua supplies places; career economy applies rewards; storage.lua captures the updated event.
local M = {}
local definitions = require('overhaul/events/motorsportEvents/definitions')
local placings = require('overhaul/events/motorsportEvents/drag/placings')
local bracket = require('overhaul/events/motorsportEvents/drag/bracket')

function M.prizes(eventState, leagueId)
  local definition = definitions.event(eventState)
  local result = {}
  for key, value in pairs(definition.prizes) do result[key] = value end
  leagueId = leagueId or eventState and (eventState.leagueId or eventState.offeredLeagueId)
    or definition.leagueIds and #definition.leagueIds == 1 and definition.leagueIds[1]
  if result.referenceLeagueId and leagueId then
    local league = assert(definitions.league(leagueId, eventState), 'Unknown reward league')
    local reference = assert(definitions.league(result.referenceLeagueId, eventState), 'Unknown prize reference league')
    for _, key in ipairs({'winner', 'runnerUp', 'third', 'topTen', 'participation'}) do
      result[key] = math.floor(result[key] * league.fee / reference.fee + .5)
    end
  end
  result.version = 2
  return result
end

function M.forPlace(place, prizes)
  prizes = prizes or M.prizes()
  return place == 1 and prizes.winner or place == 2 and prizes.runnerUp or place == 3 and prizes.third
    or place and place >= 4 and place <= 10 and prizes.topTen or place and place > 10 and prizes.participation or 0
end

function M.migrate(event)
  if not event or event.formatVersion ~= 2 or event.phase == 'complete' then return false end
  local changed, active = false, nil
  for _, session in ipairs(event.classes or {}) do
    if not session.rewardPaid and session.phase ~= 'complete' then
      if not session.prizes or session.prizes.version ~= 2 then session.prizes, changed = M.prizes(event, session.leagueId), true end
      if session.bracket and bracket.enableThirdPlace(session.bracket) then changed = true end
    end
    if session.id == event.activeClassId then active = session end
  end
  if active then event.prizes = active.prizes
  elseif not event.rewardPaid and (not event.prizes or event.prizes.version ~= 2) then event.prizes, changed = M.prizes(event), true end
  return changed
end

function M.finish(event)
  if event.rewardPaid then return true end
  local player
  for _, entrant in ipairs(event.entrants) do if entrant.player then player = entrant end end
  if not event.prizes or event.prizes.version ~= 2 then event.prizes = M.prizes(event) end
  bracket.enableThirdPlace(event.bracket)
  local ordered, err = placings.build(event.entrants, event.bracket)
  if not ordered then return false, err end
  event.placings, event.playerPlace = ordered, nil
  for _, row in ipairs(ordered) do
    row.prize = M.forPlace(row.place, event.prizes)
    if player and row.entrantId == player.id then event.playerPlace = row.place end
  end
  event.reward = M.forPlace(event.playerPlace, event.prizes)
  event.rewardPaid = true
  if event.reward > 0 then
    overhaul_career_economy_payment.reward({money = {amount = event.reward, canBeNegative = false}},
      {label = event.name .. ', place ' .. tostring(event.playerPlace), category = 'reward', tags = {'gameplay', 'reward', 'motorsport'}}, true)
  end
  return true
end

return M
