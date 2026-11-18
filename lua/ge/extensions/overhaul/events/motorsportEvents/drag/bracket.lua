-- Owns elimination bracket construction and match advancement.
-- drag/qualifying.lua supplies seeds; drag/placings.lua consumes completed matches; callers retain bracket state.
local M = {}
local qualifying = require('overhaul/events/motorsportEvents/drag/qualifying')

function M.isComplete(match)
  return match.winnerId ~= nil or match.complete == true
end

local function seededPositions(size)
  local positions = {1, 2}
  while #positions < size do
    local nextPositions, total = {}, #positions * 2 + 1
    for _, seed in ipairs(positions) do
      nextPositions[#nextPositions + 1] = seed
      nextPositions[#nextPositions + 1] = total - seed
    end
    positions = nextPositions
  end
  return positions
end

local function loser(match)
  if match.a and match.b and match.winnerId then
    local id = match.winnerId == match.a and match.b or match.a
    for _, row in ipairs(match.results or {}) do if row.entrantId == id and row.retired then return nil end end
    return id
  end
end

local function prepareChampionship(value)
  local round = value.rounds[value.currentRound]
  if not round or not (round.championship or #round.matches == 1) then return false end
  round.championship = true
  local championship = round.matches[1]
  championship.kind = 'championship'
  if not value.thirdPlaceEnabled or #round.matches > 1 then return false end
  local previous = value.rounds[value.currentRound - 1]
  if not previous or previous.championship or #previous.matches ~= 2 then return false end
  local a, b = loser(previous.matches[1]), loser(previous.matches[2])
  if not a and not b then return false end
  round.matches[2] = {id = 'r' .. tostring(round.number) .. '-third', kind = 'thirdPlace', a = a or b, b = a and b or nil,
    bye = not a or not b, winnerId = not a and b or not b and a or nil}
  if not M.isComplete(round.matches[2]) then value.winnerId, value.complete = nil, nil end
  return true
end

function M.enableThirdPlace(value)
  if not value or value.noQualified then return false end
  local changed = value.thirdPlaceEnabled ~= true
  value.thirdPlaceEnabled = true
  return prepareChampionship(value) or changed
end

function M.build(standings, fieldSize)
  local qualified, playerId = {}, nil
  for _, entrant in ipairs(standings) do
    entrant.seed = nil
    if qualifying.isLegal(entrant.qualifying) and #qualified < (fieldSize or math.huge) then
      qualified[#qualified + 1] = entrant
      entrant.seed = #qualified
      if entrant.player then playerId = entrant.id end
    end
  end
  if #qualified == 0 then return nil, 'At least one valid qualifying time is required.' end
  if #qualified == 1 then
    return {rounds = {{number = 1, championship = true, matches = {{id = 'r1-m1', kind = 'championship', a = qualified[1].id, bye = true, winnerId = qualified[1].id}}}},
      currentRound = 1, playerId = playerId, winnerId = qualified[1].id, thirdPlaceEnabled = true}
  end
  local size = 2
  while size < #qualified do size = size * 2 end
  local positions, matches = seededPositions(size), {}
  for i = 1, size, 2 do
    local a, b = qualified[positions[i]], qualified[positions[i + 1]]
    matches[#matches + 1] = {id = 'r1-m' .. tostring(#matches + 1), a = a and a.id, b = b and b.id,
      winnerId = not b and a and a.id or not a and b and b.id or nil, bye = not a or not b}
  end
  return {rounds = {{number = 1, matches = matches, championship = #matches == 1}}, currentRound = 1, playerId = playerId, thirdPlaceEnabled = true}
end

function M.nextMatch(bracket)
  if bracket.thirdPlaceEnabled then prepareChampionship(bracket) end
  if bracket.winnerId or bracket.complete then return nil end
  local round = bracket.rounds[bracket.currentRound]
  local playerMatch
  for _, match in ipairs(round.matches) do
    if not M.isComplete(match) then
      if match.a == bracket.playerId or match.b == bracket.playerId then playerMatch = match
      else return match end
    end
  end
  if playerMatch then return playerMatch end
  if round.championship or #round.matches == 1 then
    bracket.winnerId = round.matches[1].winnerId
    bracket.thirdPlaceWinnerId = round.matches[2] and round.matches[2].kind == 'thirdPlace' and round.matches[2].winnerId or nil
    bracket.complete = true
    return nil
  end
  local matches, number = {}, bracket.currentRound + 1
  for i = 1, #round.matches, 2 do
    local a, b = round.matches[i].winnerId, round.matches[i + 1].winnerId
    matches[#matches + 1] = {id = 'r' .. number .. '-m' .. tostring(#matches + 1), a = a or b, b = a and b or nil,
      bye = not a or not b, winnerId = not a and b or not b and a or nil, complete = not a and not b or nil}
  end
  bracket.currentRound = number
  bracket.rounds[number] = {number = number, matches = matches}
  return M.nextMatch(bracket)
end

function M.playerOutcome(value, playerId)
  if value and playerId then
    local entered = false
    for _, match in ipairs(value.rounds and value.rounds[1] and value.rounds[1].matches or {}) do
      if match.a == playerId or match.b == playerId then entered = true; break end
    end
    if not entered then return 'Did not qualify' end
  end
  local latest, playedRound
  for _, round in ipairs(value and value.rounds or {}) do
    for _, match in ipairs(round.matches or {}) do
      if M.isComplete(match) and (match.a == playerId or match.b == playerId) then latest, playedRound = match, round end
    end
  end
  if not latest then return nil end
  if latest.complete and not latest.winnerId then return 'Eliminated' end
  for _, row in ipairs(latest.results or {}) do if row.entrantId == playerId and row.retired then return 'Eliminated' end end
  if latest.kind == 'thirdPlace' then return latest.winnerId == playerId and '3rd place' or '4th place' end
  if latest.kind == 'championship' or playedRound.championship or #playedRound.matches == 1 then
    return latest.winnerId == playerId and 'Winner' or 'Runner-up'
  end
  if latest.winnerId == playerId then return 'Advancing' end
  if value.thirdPlaceEnabled and #playedRound.matches == 2 then return 'Third-place race next' end
  return 'Eliminated'
end

function M.record(match, result)
  if M.isComplete(match) then return false, 'This heat already has a result.' end
  if result.error then return false, result.error end
  if result.winnerId ~= match.a and result.winnerId ~= match.b then
    local seen = {}
    for _, row in ipairs(result.rows or {}) do
      if row.valid ~= false or (row.entrantId ~= match.a and row.entrantId ~= match.b) or seen[row.entrantId] then
        return false, 'The failed heat result is incomplete.'
      end
      seen[row.entrantId] = true
    end
    if result.winnerId == nil and match.a and match.b and seen[match.a] and seen[match.b] then
      match.complete, match.results = true, result.rows
      return true
    end
    return false, 'No valid winner. Run this heat again.'
  end
  match.winnerId, match.results = result.winnerId, result.rows
  match.interference = result.interference
  return true
end

return M
