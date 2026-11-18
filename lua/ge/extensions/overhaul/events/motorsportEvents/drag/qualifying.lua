-- Owns qualifying attempts, rounds, and seed ordering.
-- drag/classes.lua grades runs; drag/qualifyingSchedule.lua assigns attempts to the accepted field.
local M = {}

function M.isLegal(result)
  return result ~= nil and result.valid == true and not result.breakout
    and type(result.time) == 'number' and result.time > 0 and result.time < math.huge
end

function M.limit(entrant)
  return math.max(1, math.floor(tonumber(entrant.qualifyingLimit) or 1))
end

function M.attemptCount(entrant)
  return entrant.qualifyingAttempts and #entrant.qualifyingAttempts or entrant.qualifying and 1 or 0
end

function M.attemptAt(entrant, round)
  if entrant.qualifyingAttempts then return entrant.qualifyingAttempts[round] end
  if round == 1 then return entrant.qualifying end
end

function M.isDone(entrant)
  return entrant.qualifierDone == true or M.attemptCount(entrant) >= M.limit(entrant)
end

function M.roundInfo(entrants)
  local attempts, totalAttempts, maxRounds, minimum = 0, 0, 1, nil
  for _, entrant in ipairs(entrants or {}) do
    local limit, count = M.limit(entrant), M.attemptCount(entrant)
    attempts, totalAttempts, maxRounds = attempts + math.min(count, limit), totalAttempts + limit, math.max(maxRounds, limit)
    if not M.isDone(entrant) then minimum = math.min(minimum or count, count) end
  end
  local round = minimum and math.min(minimum + 1, maxRounds) or maxRounds
  local roundAttempts, roundTotal = 0, 0
  for _, entrant in ipairs(entrants or {}) do
    if M.limit(entrant) >= round then
      roundTotal = roundTotal + 1
      if M.attemptCount(entrant) >= round then roundAttempts = roundAttempts + 1 end
    end
  end
  return {number = round, maxRounds = maxRounds, attempts = attempts, totalAttempts = totalAttempts,
    roundAttempts = roundAttempts, roundTotal = roundTotal, complete = minimum == nil}
end

function M.orderForRound(entrants, round)
  local ranked = {}
  for index, entrant in ipairs(entrants or {}) do
    if M.limit(entrant) >= round then
      local best
      for previous = 1, round - 1 do
        local result = M.attemptAt(entrant, previous)
        local time = result and result.time
        if M.isLegal(result) then
          best = math.min(best or time, time)
        end
      end
      ranked[#ranked + 1] = {entrant = entrant, time = best or math.huge, index = index}
    end
  end
  table.sort(ranked, function(a, b) return a.time == b.time and a.index < b.index or a.time < b.time end)
  local ordered = {}
  for _, row in ipairs(ranked) do ordered[#ordered + 1] = row.entrant end
  return ordered
end

function M.physicalGroup(entrants, round)
  local ordered = M.orderForRound(entrants, round)
  local playerIndex
  for index, entrant in ipairs(ordered) do if entrant.player then playerIndex = index; break end end
  if not playerIndex then return nil end
  local first = math.max(1, math.min(math.floor((playerIndex - 1) / 6) * 6 + 1, #ordered - 5))
  local group = {}
  for index = first, math.min(first + 5, #ordered) do group[#group + 1] = ordered[index] end
  return group
end

function M.roundHeats(entrants)
  local info, players, pending, heats = M.roundInfo(entrants), {}, {}, {}
  if info.complete then return heats end
  if info.number > 1 then
    local ordered = M.orderForRound(entrants, info.number)
    for index = 1, #ordered, 2 do
      local pair, attempts = {}, {}
      for lane = index, math.min(index + 1, #ordered) do
        local entrant = ordered[lane]
        if not M.isDone(entrant) and M.attemptCount(entrant) == info.number - 1 then
          pair[#pair + 1], attempts[#attempts + 1] = entrant, info.number - 1
        end
      end
      if #pair > 0 then heats[#heats + 1] = {entrants = pair, attempts = attempts} end
    end
    return heats
  end
  for _, entrant in ipairs(entrants or {}) do
    if not M.isDone(entrant) and M.attemptCount(entrant) == info.number - 1 then
      local rows = entrant.player and players or pending
      rows[#rows + 1] = entrant
    end
  end
  local function add(a, b)
    heats[#heats + 1] = {entrants = {a, b}, attempts = {M.attemptCount(a), b and M.attemptCount(b)}}
  end
  local index = 1
  for _, player in ipairs(players) do add(player, pending[index]); index = index + 1 end
  for i = index, #pending, 2 do add(pending[i], pending[i + 1]) end
  return heats
end

function M.record(entrant, result)
  if M.isDone(entrant) then return false end
  local attempt = {
    time = result.time, reaction = result.reaction,
    valid = M.isLegal(result),
    reason = result.reason, simulated = result.simulated == true,
    nativeValid = result.nativeValid, nativeReason = result.nativeReason,
    qualifyingRedLight = result.qualifyingRedLight == true, boundaryViolation = result.boundaryViolation == true,
    breakout = result.breakout == true, breakoutAmount = result.breakoutAmount,
  }
  entrant.qualifyingAttempts = entrant.qualifyingAttempts or (entrant.qualifying and {entrant.qualifying} or {})
  entrant.qualifyingAttempts[#entrant.qualifyingAttempts + 1] = attempt
  local best = entrant.qualifying
  if not M.isLegal(best) or M.isLegal(attempt) and attempt.time < best.time then entrant.qualifying = attempt end
  entrant.qualifierDone = #entrant.qualifyingAttempts >= M.limit(entrant)
  return true
end

function M.recordAt(entrant, round, result)
  if not entrant or entrant.player then return false, 'Only opponent qualifying attempts can be replaced.' end
  if type(round) ~= 'number' or round ~= math.floor(round) or round < 1 or round > M.limit(entrant) then
    return false, 'The qualifying attempt is unavailable.'
  end
  if type(result) ~= 'table' or result.simulated then return false, 'A physical qualifying result is required.' end
  local previous = M.attemptAt(entrant, round)
  if previous and previous.simulated ~= true then return false, 'A physical qualifying attempt cannot be overwritten.' end
  if not previous and M.attemptCount(entrant) ~= round - 1 then return false, 'An earlier qualifying attempt is unfinished.' end
  local holder = {qualifyingLimit = 1}
  M.record(holder, result)
  local attempt = holder.qualifyingAttempts[1]
  attempt.simulated = false
  entrant.qualifyingAttempts = entrant.qualifyingAttempts or (entrant.qualifying and {entrant.qualifying} or {})
  entrant.qualifyingAttempts[round] = attempt
  local best, fallback
  for _, row in ipairs(entrant.qualifyingAttempts) do
    fallback = row
    if M.isLegal(row)
      and (not best or row.time < best.time) then best = row end
  end
  entrant.qualifying = best or fallback
  entrant.qualifierDone = #entrant.qualifyingAttempts >= M.limit(entrant)
  return true
end

function M.pending(entrants)
  local rows = {}
  for index, entrant in ipairs(entrants) do
    if not M.isDone(entrant) then rows[#rows + 1] = {entrant = entrant, index = index, count = M.attemptCount(entrant)} end
  end
  table.sort(rows, function(a, b)
    if (a.entrant.player == true) ~= (b.entrant.player == true) then return a.entrant.player ~= true end
    if a.count ~= b.count then return a.count < b.count end
    return a.index < b.index
  end)
  local result = {}
  for _, row in ipairs(rows) do result[#result + 1] = row.entrant end
  return result
end

function M.nextEntrant(entrants)
  return M.pending(entrants)[1]
end

function M.nextPair(entrants)
  if M.roundInfo(entrants).maxRounds > 1 then
    local heat = M.roundHeats(entrants)[1]
    return heat and heat.entrants
  end
  local pending, player = {}, nil
  for _, entrant in ipairs(M.pending(entrants)) do
    if entrant.player then player = entrant else pending[#pending + 1] = entrant end
  end
  if #pending >= 2 then return {pending[1], pending[2]} end
  if #pending == 1 and player then return {pending[1], player} end
  local remaining = pending[1] or player
  if remaining then
    if M.limit(remaining) > 1 then return {remaining} end
    for _, entrant in ipairs(entrants) do
      if entrant ~= remaining and not entrant.player then return {remaining, entrant} end
    end
    return {remaining}
  end
end

-- Attempt numbers are already saved; equal bests use the earlier attempt,
-- then the original field order, regardless of driver number or player status.
function M.standings(entrants, field)
  local fieldOrder = {}
  for index, entrant in ipairs(field or entrants or {}) do fieldOrder[entrant.id or entrant] = index end
  local fieldSize = #(field or entrants or {})
  local ranked = {}
  for index, entrant in ipairs(entrants or {}) do
    local legal = M.isLegal(entrant.qualifying)
    local time = legal and entrant.qualifying.time or math.huge
    local attempt = math.huge
    if legal then
      for round = 1, M.attemptCount(entrant) do
        local result = M.attemptAt(entrant, round)
        if M.isLegal(result) and result.time == time then attempt = round; break end
      end
    end
    ranked[#ranked + 1] = {entrant = entrant, index = index, order = fieldOrder[entrant.id or entrant] or fieldSize + index, time = time, attempt = attempt,
      category = legal and 1 or (M.attemptCount(entrant) > 0 or entrant.qualifierDone) and 2 or 3}
  end
  table.sort(ranked, function(a, b)
    if a.category ~= b.category then return a.category < b.category end
    if a.time ~= b.time then return a.time < b.time end
    if a.attempt ~= b.attempt then return a.attempt < b.attempt end
    if a.order ~= b.order then return a.order < b.order end
    return a.index < b.index
  end)
  local rows = {}
  for _, row in ipairs(ranked) do rows[#rows + 1] = row.entrant end
  return rows
end

return M
