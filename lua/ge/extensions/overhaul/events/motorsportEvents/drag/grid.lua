-- Owns qualifying and elimination grid ordering.
-- drag/qualifying.lua and drag/bracket.lua provide heat data; drag/parking.lua consumes ordered groups.
local M = {}
local qualifying = require('overhaul/events/motorsportEvents/drag/qualifying')
local qualifyingSchedule = require('overhaul/events/motorsportEvents/drag/qualifyingSchedule')

local function qualifyingPending(heat, index)
  local entrant = heat.entrants[index]
  if heat.spectatorRound then
    local attempt = qualifying.attemptAt(entrant, heat.spectatorRound)
    return not attempt or attempt.simulated == true
  end
  return not qualifying.isDone(entrant) and (not heat.attempts or qualifying.attemptCount(entrant) <= (heat.attempts[index] or 0))
end

function M.sortSpots(spots)
  table.sort(spots, function(a, b)
    local depthA = tonumber(a.name:match('_(%d+)$')) or 0
    local depthB = tonumber(b.name:match('_(%d+)$')) or 0
    if depthA ~= depthB then return depthA < depthB end
    return a.name < b.name
  end)
end

local function heats(eventState)
  local result, byId = {}, {}
  if eventState.spectatorHeats then
    for _, heat in ipairs(eventState.spectatorHeats) do if not M.heatFinished(heat) then result[#result + 1] = heat end end
    return result
  end
  if eventState.phase == 'registration' then return result end
  if (eventState.phase == 'qualifying' or eventState.phase == 'playerQualifying') and qualifying.roundInfo(eventState.entrants).maxRounds > 1 then
    return qualifying.roundHeats(eventState.entrants)
  end
  if eventState.phase == 'playerQualifying' then
    for _, entrant in ipairs(eventState.entrants or {}) do
      if entrant.player and not qualifying.isDone(entrant) then
        local heat = {entrants = {entrant}, attempts = {qualifying.attemptCount(entrant)}}
        for _, opponent in ipairs(eventState.entrants) do
          if not opponent.player and not qualifying.isDone(opponent) then
            heat.entrants[2], heat.attempts[2] = opponent, qualifying.attemptCount(opponent)
            break
          end
        end
        return {heat}
      end
    end
    return result
  end
  for _, entrant in ipairs(eventState.entrants) do byId[entrant.id] = entrant end
  if eventState.bracket then
    local round = eventState.bracket.rounds[eventState.bracket.currentRound]
    if not round then return result end
    local playerHeat
    for _, match in ipairs(round.matches) do
      if not match.winnerId and not match.complete then
        local heat = {entrants = {byId[match.a], byId[match.b]}, match = match}
        if heat.entrants[1].player or heat.entrants[2].player then playerHeat = heat
        else result[#result + 1] = heat end
      end
    end
    if playerHeat then result[#result + 1] = playerHeat end
  else
    local pending, player = {}, nil
    for _, entrant in ipairs(qualifying.pending(eventState.entrants)) do
      if entrant.player then player = entrant else pending[#pending + 1] = entrant end
    end
    for i = 1, #pending, 2 do
      local opponent = pending[i + 1]
      if not opponent then
        opponent, player = player, nil
        if not opponent and qualifying.limit(pending[i]) <= 1 then
          for _, entrant in ipairs(eventState.entrants) do if not entrant.player and entrant ~= pending[i] then opponent = entrant; break end end
        end
      end
      result[#result + 1] = {entrants = {pending[i], opponent}, attempts = {qualifying.attemptCount(pending[i]), opponent and qualifying.attemptCount(opponent)}}
    end
    if player then
      local opponent
      if qualifying.limit(player) <= 1 then
        for _, entrant in ipairs(eventState.entrants) do if not entrant.player then opponent = entrant; break end end
      end
      result[#result + 1] = {entrants = {player, opponent}, attempts = {qualifying.attemptCount(player), opponent and qualifying.attemptCount(opponent)}}
    end
  end
  return result
end

function M.order(eventState)
  local rows = {}
  for _, heat in ipairs(heats(eventState)) do for _, entrant in ipairs(heat.entrants) do rows[#rows + 1] = entrant end end
  return rows
end

M.queue = heats

local function fullRoundHeats(eventState, qualifyingRound)
  if eventState.spectatorHeats then return eventState.spectatorHeats end
  if qualifyingSchedule.enabled(eventState) then return qualifyingSchedule.heats(eventState, qualifyingRound) or {} end
  if eventState.bracket then
    local round = eventState.bracket.rounds[eventState.bracket.currentRound]
    if not round then return {} end
    local rows, byId, player = {}, {}, nil
    for _, entrant in ipairs(eventState.entrants or {}) do byId[entrant.id] = entrant end
    for _, match in ipairs(round.matches) do
      if match.a and match.b then
        local heat = {entrants = {byId[match.a], byId[match.b]}, match = match}
        if heat.entrants[1].player or heat.entrants[2].player then player = heat else rows[#rows + 1] = heat end
      end
    end
    if player then rows[#rows + 1] = player end
    return rows
  end
  local round = qualifyingRound or qualifying.roundInfo(eventState.entrants).number
  if round > 1 then
    local ordered, rows = qualifying.orderForRound(eventState.entrants, round), {}
    for index = 1, #ordered, 2 do
      rows[#rows + 1] = {entrants = {ordered[index], ordered[index + 1]}, attempts = {round - 1, ordered[index + 1] and round - 1}}
    end
    return rows
  end
  local players, opponents, rows = {}, {}, {}
  for _, entrant in ipairs(eventState.entrants or {}) do
    if qualifying.limit(entrant) >= round then
      local target = entrant.player and players or opponents
      target[#target + 1] = entrant
    end
  end
  local function add(a, b)
    rows[#rows + 1] = {entrants = {a, b}, attempts = {round - 1, b and round - 1}}
  end
  local index = 1
  for _, player in ipairs(players) do add(player, opponents[index]); index = index + 1 end
  for i = index, #opponents, 2 do add(opponents[i], opponents[i + 1]) end
  return rows
end

local function legalTime(entrant)
  local best
  local function consider(result)
    local time = result and result.time
    if result and result.valid == true and not result.breakout
      and type(time) == 'number' and time > 0 and time < math.huge then best = math.min(best or time, time) end
  end
  consider(entrant.qualifying)
  for _, result in ipairs(entrant.qualifyingAttempts or {}) do consider(result) end
  return best
end

local function orderHeats(group)
  local ranked, slots = {}, {}
  for index, heat in ipairs(group.heats) do
    local first, second = legalTime(heat.entrants[1]), heat.entrants[2] and legalTime(heat.entrants[2])
    if first and (not heat.entrants[2] or second) then
      if second and second < first then
        heat.entrants[1], heat.entrants[2] = heat.entrants[2], heat.entrants[1]
        if heat.attempts then heat.attempts[1], heat.attempts[2] = heat.attempts[2], heat.attempts[1] end
      end
      ranked[#ranked + 1] = {heat = heat, time = math.min(first, second or first), index = index}
      slots[#slots + 1] = index
    end
  end
  table.sort(ranked, function(a, b) return a.time == b.time and a.index < b.index or a.time < b.time end)
  for index, row in ipairs(ranked) do group.heats[slots[index]] = row.heat end
  group.entrants, group.assignments = {}, {}
  for heatIndex, heat in ipairs(group.heats) do
    for lane, entrant in ipairs(heat.entrants) do
      group.entrants[#group.entrants + 1] = entrant
      group.assignments[entrant.id] = (heatIndex - 1) * 2 + lane
    end
  end
end

function M.groups(eventState, qualifyingRound)
  local groups, group = {}, nil
  if eventState.phase == 'registration' then return groups end
  for _, heat in ipairs(fullRoundHeats(eventState, qualifyingRound)) do
    if not group or #group.entrants + #heat.entrants > 6 then
      group = {number = #groups + 1, heats = {}, entrants = {}, assignments = {}}
      groups[#groups + 1] = group
    end
    group.heats[#group.heats + 1] = heat
    for _, entrant in ipairs(heat.entrants) do
      group.entrants[#group.entrants + 1] = entrant
      group.assignments[entrant.id] = #group.entrants
    end
  end
  if eventState.bracket then for _, item in ipairs(groups) do orderHeats(item) end end
  return groups
end

function M.nextGroup(eventState)
  local groups = M.groups(eventState)
  for _, group in ipairs(groups) do
    if not M.batchFinished(group.heats) then return group, #groups end
  end
  return nil, #groups
end

function M.assign(eventState, capacity)
  local rows, result, batch = {}, {}, {}
  for _, heat in ipairs(heats(eventState)) do
    if #rows + #heat.entrants > capacity then break end
    local duplicate = false
    for _, entrant in ipairs(heat.entrants) do if result[entrant.id] then duplicate = true end end
    if duplicate then break end
    for _, entrant in ipairs(heat.entrants) do
      rows[#rows + 1] = entrant
      result[entrant.id] = #rows
    end
    batch[#batch + 1] = heat
  end
  return result, rows, batch
end

function M.heatFinished(heat)
  if heat.match then return heat.match.winnerId ~= nil or heat.match.complete == true end
  for index in ipairs(heat.entrants) do if qualifyingPending(heat, index) then return false end end
  return true
end

function M.batchFinished(batch)
  if not batch or #batch == 0 then return false end
  for _, heat in ipairs(batch) do if not M.heatFinished(heat) then return false end end
  return true
end

function M.isPending(batch, entrantId)
  for _, heat in ipairs(batch or {}) do
    if not M.heatFinished(heat) then
      for _, entrant in ipairs(heat.entrants) do if entrant.id == entrantId then return true end end
    end
  end
  return false
end

function M.isEntrantPending(batch, entrantId)
  for _, heat in ipairs(batch or {}) do
    for index, entrant in ipairs(heat.entrants) do
      if entrant.id == entrantId then
        if heat.match then return heat.match.winnerId == nil and not heat.match.complete end
        return qualifyingPending(heat, index)
      end
    end
  end
  return false
end

function M.nextPair(batch, skipPlayer)
  for _, heat in ipairs(batch or {}) do
    local player = false
    for _, entrant in ipairs(heat.entrants) do if entrant.player then player = true; break end end
    if not (skipPlayer and player) and heat.match then
      if not heat.match.winnerId and not heat.match.complete then return heat.entrants end
    elseif not (skipPlayer and player) then
      local entrants = {}
      for index, entrant in ipairs(heat.entrants) do
        if qualifyingPending(heat, index) then entrants[#entrants + 1] = entrant end
      end
      if #entrants > 0 then return entrants end
    end
  end
end

return M
