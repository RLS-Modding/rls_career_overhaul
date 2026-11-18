-- Owns NPC staging recovery and retry decisions.
-- drag/runner.lua owns the pass lifetime; drag/staging.lua owns staging holds; player vehicles remain caller-owned.
local M = {}
local currentData, states, launched = nil, {}, false

local function finite(value)
  return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function vector(value)
  local kind = type(value)
  return (kind == 'table' or kind == 'userdata' or kind == 'cdata') and finite(value.x) and finite(value.y) and finite(value.z)
end

local function stagingOnly(data)
  local count = 0
  for _, racer in pairs(data and data.racers or {}) do
    if not racer.isFinished and not racer.vehicleRemoved then
      count = count + 1
      local phase = racer.phases and racer.phases[racer.currentPhase]
      if racer.currentPhase ~= 1 or not phase or phase.name ~= 'stage' or racer.treeStarted or racer.timersStarted then return false end
    end
  end
  return count > 0
end

local function failure(state, reason)
  state.error = 'Could not recover ' .. tostring(state.name or 'the NPC') .. ' before staging: ' .. reason
  return nil, state.error
end

local function repair(state, data, vehicle)
  if not stagingOnly(data) then return true end
  if state.recovered then return failure(state, 'the second staging attempt failed.') end
  local lane = data.strip and data.strip.lanes and data.strip.lanes[state.lane]
  local transform = lane and lane.waypoints and lane.waypoints.spawn and lane.waypoints.spawn.transform
  if not transform or not vector(transform.pos) or not vector(transform.rot) or not finite(transform.rot.w)
    or not spawn or type(spawn.safeTeleport) ~= 'function' or not gameplay_drag_core
    or type(gameplay_drag_core.setupRacer) ~= 'function' or type(vehicle.reset) ~= 'function'
    or type(vehicle.queueLuaCommand) ~= 'function' then
    return failure(state, 'the lane recovery position is unavailable.')
  end
  local racer = data.racers[state.id]
  state.name, state.dial = racer.niceName or state.name, racer.timers and racer.timers.dial and racer.timers.dial.value
  racer.phases[1].started, racer.phases[1].completed = true, false
  local ok = pcall(function()
    vehicle:queueLuaCommand("ai:scriptStop(true, true); electrics.values.throttleOverride = nil; input.event('parkingbrake', 0, 2)")
    vehicle:reset()
    spawn.safeTeleport(vehicle, transform.pos, transform.rot, nil, nil, false, true, false)
  end)
  if not ok then return failure(state, 'the vehicle could not be repaired and repositioned.') end
  state.recovered, state.pending, state.elapsed = true, 'settle', 0
  return true
end

local function updateStaging(rows, data, dtSim)
  if data ~= currentData then currentData, states, launched = data, {}, false end
  for _, racer in pairs(data and data.racers or {}) do
    if not racer.isFinished and not racer.vehicleRemoved
      and (racer.treeStarted or racer.timersStarted or (racer.currentPhase or 1) > 1) then launched = true end
  end
  if launched or not stagingOnly(data) then return true end
  local dt = finite(dtSim) and math.max(0, dtSim) or 0
  local pending = false
  for _, row in ipairs(rows or {}) do
    local racer = data.racers[row.id]
    if row.entrant and not row.entrant.player and racer and not racer.isPlayable and not racer.isFinished and not racer.vehicleRemoved
      and row.id ~= be:getPlayerVehicleID(0) then
      local state = states[row.id]
      if not state then
        state = {id = row.id, lane = row.lane, name = row.entrant.name, stageElapsed = 0, overshot = 0, inverted = 0}
        states[row.id] = state
      end
      local vehicle = be:getObjectByID(row.id)
      if not vehicle then states[row.id] = nil; goto continue end
      if state.error then return nil, state.error end
      if state.pending then
        state.elapsed = state.elapsed + dt
        if state.elapsed >= .5 then
          local setupOk = pcall(gameplay_drag_core.setupRacer, row.id, row.lane)
          racer = data.racers[row.id]
          if not setupOk or not racer or not racer.timers or not racer.timers.dial then return failure(state, 'the NPC could not be registered again.') end
          local dial = finite(state.dial) and state.dial or finite(row.entrant.dial) and row.entrant.dial or 10
          racer.isPlayable, racer.niceName, racer.timers.dial.value = false, state.name, dial
          state.pending, state.stageElapsed, state.overshot, state.inverted = nil, 0, 0, 0
        end
      else
        local handler = gameplay_drag_phaseHandlers
        local ok, distance = false, nil
        if handler and type(handler.getFrontWheelDistanceFromStagePos) == 'function' then
          ok, distance = pcall(handler.getFrontWheelDistanceFromStagePos, racer)
        end
        local validDistance = ok and finite(distance)
        state.overshot = validDistance and distance > .35 and state.overshot + dt or 0
        local up = racer.vehDirectionVectorUp
        local knownUp = vector(up) and up.x * up.x + up.y * up.y + up.z * up.z > .5
        state.inverted = knownUp and up.z < .2 and state.inverted + dt or 0
        local staged = validDistance and distance >= -.178 and distance < .178
          and racer.beamState and racer.beamState[racer.frontWheelId] and racer.beamState[racer.frontWheelId].stage
        state.stageElapsed = staged and 0 or state.stageElapsed + dt
        if state.overshot >= 1 or state.inverted >= 1 or state.stageElapsed >= 30 then
          local repaired, err = repair(state, data, vehicle)
          if not repaired then return nil, err end
        end
      end
      pending = pending or state.pending ~= nil
    end
    ::continue::
  end
  return not pending
end

function M.updateStaging(rows, data, dtSim, disqualify)
  local ready, err = updateStaging(rows, data, dtSim)
  if not err or not disqualify or not stagingOnly(data) then return ready, err end
  for _, row in ipairs(rows or {}) do
    local state = states[row.id]
    if state and state.error and not row.entrant.player and row.id ~= be:getPlayerVehicleID(0) then
      disqualify(row, data)
      states[row.id] = nil
      return true
    end
  end
  return ready, err
end

function M.clear() currentData, states, launched = nil, {}, false end

return M
