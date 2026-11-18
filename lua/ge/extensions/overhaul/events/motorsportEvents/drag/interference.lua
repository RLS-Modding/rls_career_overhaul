-- Owns drag foul and terminal-failure classification.
-- drag/runner.lua supplies racer evidence; drag/classes.lua preserves those causes while grading results.
local M = {}
local LANE = 'missions.dragRace.gameplay.disqualified.outOfLane'

local function finite(n) return type(n) == 'number' and n == n and math.abs(n) < math.huge end
local function position(p)
  local kind = type(p)
  return (kind == 'table' or kind == 'userdata' or kind == 'cdata') and finite(p.x) and finite(p.y) and finite(p.z)
end
local function reason(r) return r.disqualifiedReason or r.desqualifiedReason end
local function disqualified(r) return r.isDisqualified or r.isDesqualified or r.vehicleRemoved end

local function points(racer)
  local result = {}
  if racer.wheelsCenter and next(racer.wheelsCenter) then
    for key, wheel in pairs(racer.wheelsCenter) do
      if not wheel or not position(wheel.pos) then return end
      result[key] = vec3(wheel.pos)
    end
  elseif position(racer.vehPos) then result.center = vec3(racer.vehPos)
  else return end
  return result
end

local function crossing(a, b, inside)
  if not a or inside(a) or not inside(b) then return end
  local lo, hi = 0, 1
  for _ = 1, 12 do
    local mid = (lo + hi) / 2
    if inside(a + (b - a) * mid) then hi = mid else lo = mid end
  end
  return hi
end

function M.observe(state, rows, data)
  if #rows ~= 2 or not data.strip or not data.strip.lanes then return end
  local previous, snapshots, candidates = state.previous or {}, {}, {}
  state.sample = (state.sample or 0) + 1
  for _, row in ipairs(rows) do
    local racer, lane = data.racers[row.id], data.strip.lanes[row.lane]
    if racer and lane and lane.zone and type(lane.zone.containsPoint2D) == 'function' then
      local p = points(racer)
      local clean = p ~= nil and not disqualified(racer)
      for _, point in pairs(p or {}) do if not lane.zone:containsPoint2D(point) then clean = false end end
      snapshots[row.id] = {points = p, clean = clean}
    end
  end
  for index, row in ipairs(rows) do
    local other = rows[3 - index]
    local racer, victim = data.racers[row.id], data.racers[other.id]
    local before, affectedBefore = previous[row.id], previous[other.id]
    local now, affectedNow = snapshots[row.id], snapshots[other.id]
    local lane, otherLane = data.strip.lanes[row.lane], data.strip.lanes[other.lane]
    local timer = racer and racer.timers and racer.timers.time_1_4
    local victimTimer = victim and victim.timers and victim.timers.time_1_4
    if racer and victim and racer.timersStarted and before and before.points and affectedBefore and affectedBefore.clean
      and now and now.points and affectedNow and affectedNow.points and not (timer and timer.isSet)
      and not (victimTimer and victimTimer.isSet) and not victim.vehicleRemoved
      and (not disqualified(victim) or reason(victim) == LANE) then
      local origin = lane.waypoints.stage.transform.pos
      local target = otherLane.waypoints.stage.transform.pos
      local sideways = vec3(target.x - origin.x, target.y - origin.y, 0)
      if sideways:length() > .1 then
        sideways:normalize()
        local mid = (origin + target) * .5
        local function invading(p) return (p - mid):dot(sideways) > .05 and otherLane.zone:containsPoint2D(p) end
        local entered
        for key, point in pairs(now.points) do
          local fraction = crossing(before.points[key], point, invading)
          if fraction then entered = math.min(entered or 1, fraction) end
        end
        if entered then
          local escaped = 2
          for key, point in pairs(affectedNow.points) do
            local fraction = crossing(affectedBefore.points[key], point, function(p) return not otherLane.zone:containsPoint2D(p) end)
            if fraction then escaped = math.min(escaped, fraction) end
          end
          if entered + .001 < escaped then
            candidates[#candidates + 1] = {offenderId = row.entrant.id, affectedId = other.entrant.id,
              offenderLane = row.lane, affectedLane = other.lane, sample = state.sample, fraction = entered, source = 'laneIncursion'}
          end
        end
      end
    end
  end
  state.previous = snapshots
  if #candidates == 1 then return candidates[1] end
end

function M.result(incident)
  return {walkover = true, winnerId = incident.affectedId, interference = incident, rows = {
    {entrantId = incident.affectedId, valid = true, nativeValid = false, walkover = true, reason = 'Opponent lane interference'},
    {entrantId = incident.offenderId, valid = false, nativeValid = false, nativeReason = LANE, reason = LANE, retired = true},
  }}
end

function M.validate(result, eventState)
  local incident, found = result.interference, {}
  if not incident or incident.offenderId == incident.affectedId or result.winnerId ~= incident.affectedId
    or (incident.source ~= 'laneIncursion' and incident.source ~= 'steward') or #result.rows ~= 2 then return false end
  if incident.source == 'laneIncursion' and (not finite(incident.sample) or incident.sample < 1
    or not finite(incident.fraction) or incident.fraction < 0 or incident.fraction > 1) then return false end
  for _, entrant in ipairs(eventState and eventState.entrants or {}) do found[entrant.id] = true end
  if not found[incident.offenderId] or not found[incident.affectedId] then return false end
  local seen = {}
  for _, row in ipairs(result.rows) do
    if seen[row.entrantId] or row.time ~= nil or row.reaction ~= nil then return false end
    seen[row.entrantId] = true
    if row.entrantId == incident.affectedId then
      if row.valid ~= true or not row.walkover or row.retired then return false end
    elseif row.entrantId ~= incident.offenderId or row.valid ~= false or row.reason ~= LANE then return false end
  end
  return seen[incident.affectedId] and seen[incident.offenderId] or false
end

return M
