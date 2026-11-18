-- Owns finish-order comparison and elapsed-time extraction.
-- drag/runner.lua supplies native racer data; drag/classes.lua uses the normalized results for grading.
local M = {}
local function finite(value) return type(value) == 'number' and value == value and math.abs(value) < math.huge end

function M.observe(row, racer, sample)
  if row.finishOrder or not racer or not racer.timers then return end
  local timer = racer.timers.time_1_4
  if not timer then return end
  local distance, previous = racer.currentDistanceFromOrigin, racer.previousDistanceFromOrigin
  local finish = finite(timer.distance) and timer.distance or 402.336
  if finite(distance) and distance >= finish and (racer.timersStarted or timer.isSet) then
    local fraction = finite(previous) and previous < finish and distance > previous
      and math.max(0, math.min(1, (finish - previous) / (distance - previous))) or 1
    -- Frame plus crossing fraction, independent of launch time and elapsed time.
    row.finishOrder = sample + fraction
  elseif timer.isSet and finite(timer.value) and timer.value > 0 then
    row.finishOrder = sample + 1
  end
end

function M.winner(rows, preferred)
  if not rows or #rows == 0 then return end
  local observed = true
  for _, row in ipairs(rows) do if not finite(row.finishOrder) then observed = false; break end end
  if not observed then
    for _, row in ipairs(rows) do if row.entrantId == preferred then return preferred end end
  end
  local ordered = {}
  for index, row in ipairs(rows) do ordered[index] = row end
  table.sort(ordered, function(a, b)
    if observed and a.finishOrder ~= b.finishOrder then return a.finishOrder < b.finishOrder end
    local at, bt = tonumber(a.time), tonumber(b.time)
    local ar, br = tonumber(a.reaction), tonumber(b.reaction)
    local af = finite(at) and finite(ar) and at + ar or math.huge
    local bf = finite(bt) and finite(br) and bt + br or math.huge
    if af ~= bf then return af < bf end
    return tostring(a.entrantId) < tostring(b.entrantId)
  end)
  return ordered[1].entrantId
end

return M
