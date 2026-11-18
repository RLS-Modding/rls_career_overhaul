-- Owns final class placing rows.
-- drag/bracket.lua owns match state; rewards.lua consumes places without inventing unfinished results.
local M = {}

local function bestTime(entrant)
  local best
  local function consider(row)
    local time = row and row.time
    if row and row.valid == true and not row.breakout and type(time) == 'number' and time > 0 and time < math.huge then best = math.min(best or time, time) end
  end
  consider(entrant.qualifying)
  for _, row in ipairs(entrant.qualifyingAttempts or {}) do consider(row) end
  return best
end

local function loser(match)
  if match and match.a and match.b and match.winnerId then return match.winnerId == match.a and match.b or match.a end
end

function M.build(entrants, bracket)
  if not bracket or bracket.noQualified then return {} end
  if not bracket.winnerId and not bracket.complete then return nil, 'Finish every championship and third-place race before awarding prizes.' end
  local byId, eliminated, championship, third = {}, {}
  local admitted = {}
  for _, match in ipairs(bracket.rounds and bracket.rounds[1] and bracket.rounds[1].matches or {}) do
    if match.a then admitted[match.a] = true end
    if match.b then admitted[match.b] = true end
  end
  for _, entrant in ipairs(entrants or {}) do
    local time = bestTime(entrant)
    if time and admitted[entrant.id] then byId[entrant.id] = {entrantId = entrant.id, qualifyingTime = time, seed = entrant.seed} end
  end
  for _, round in ipairs(bracket.rounds or {}) do
    for _, match in ipairs(round.matches or {}) do
      if match.kind == 'thirdPlace' then third = match
      else
        if match.kind == 'championship' or round.championship or #round.matches == 1 then championship = match end
        local id = loser(match)
        if id then eliminated[id] = round.number end
        if match.complete and not match.winnerId then
          if match.a then eliminated[match.a] = round.number end
          if match.b then eliminated[match.b] = round.number end
        end
      end
    end
  end
  local ordered, placed = {}, {}
  local nextPlace = 1
  local function add(id, place)
    local row = id and byId[id]
    if row and not placed[id] then
      row.place = place or nextPlace
      nextPlace = row.place + 1
      placed[id], row.eliminatedRound = true, eliminated[id]
      ordered[#ordered + 1] = row
    end
  end
  add(bracket.winnerId, 1)
  add(loser(championship), 2)
  nextPlace = 3
  if third then
    if not third.winnerId and not third.complete then return nil, 'Finish the third-place race before awarding prizes.' end
    add(third.winnerId, 3)
    add(loser(third), 4)
    nextPlace = 5
  end
  local remaining = {}
  for id, row in pairs(byId) do
    if not placed[id] then
      if not eliminated[id] then return nil, 'The final elimination standings are incomplete.' end
      row.eliminatedRound = eliminated[id]
      remaining[#remaining + 1] = row
    end
  end
  table.sort(remaining, function(a, b)
    if a.eliminatedRound ~= b.eliminatedRound then return a.eliminatedRound > b.eliminatedRound end
    if a.qualifyingTime ~= b.qualifyingTime then return a.qualifyingTime < b.qualifyingTime end
    if (a.seed or math.huge) ~= (b.seed or math.huge) then return (a.seed or math.huge) < (b.seed or math.huge) end
    return tostring(a.entrantId) < tostring(b.entrantId)
  end)
  for _, row in ipairs(remaining) do add(row.entrantId) end
  return ordered
end

return M
