-- Owns NPC staging hold installation and release.
-- drag/runner.lua owns held racers; vehicle/extensions/overhaulMotorsportStagingHold.lua applies vehicle-side control.
local M = {}

function M.clear(rows)
  for _, row in ipairs(rows or {}) do
    if row.stagingHoldRacer then
      local vehicle = be:getObjectByID(row.id)
      if vehicle then vehicle:queueLuaCommand("extensions.unload('overhaulMotorsportStagingHold')") end
      row.stagingHoldRacer = nil
    end
  end
end

function M.update(rows, data)
  for _, row in ipairs(rows) do
    local racer = data.racers[row.id]
    local phase = racer and racer.phases and racer.phases[racer.currentPhase]
    local waiting = not row.entrant.player and row.id ~= be:getPlayerVehicleID(0) and racer
      and not racer.rlsReactionReleased and not racer.isFinished and not racer.isDisqualified and not racer.isDesqualified and not racer.vehicleRemoved
      and phase and (phase.name == 'stage' and phase.completed or phase.name == 'countdown' or phase.name == 'race' and not phase.started)
    if waiting then
      if row.stagingHoldRacer ~= racer then
        M.clear({row})
        local vehicle = be:getObjectByID(row.id)
        if vehicle then
          vehicle:queueLuaCommand("extensions.load('overhaulMotorsportStagingHold'); overhaulMotorsportStagingHold.hold()")
          row.stagingHoldRacer = racer
        end
      end
    else M.clear({row}) end
  end
end

function M.attach(data, rows)
  local handler = gameplay_drag_phaseHandlers
  if not data or not handler then return function() M.clear(rows) end end
  local originalStaged, originalCountdown = handler.areAllRacersStaged, handler.countdown
  local settledFor = {}
  local function staged(racer)
    if type(handler.getFrontWheelDistanceFromStagePos) ~= 'function' then return end
    local ok, distance = pcall(handler.getFrontWheelDistanceFromStagePos, racer)
    local beam = racer.beamState and racer.beamState[racer.frontWheelId]
    if not ok or type(distance) ~= 'number' or distance ~= distance or not beam then return end
    return racer.inLane ~= false and beam.stage == true and distance >= -.178 and distance < .178
      and (type(racer.vehSpeed) ~= 'number' or racer.vehSpeed < .5)
  end
  local function reset(racer)
    settledFor[racer] = nil
    local phase = racer.phases and racer.phases[1]
    if not phase then return end
    racer.currentPhase = 1
    phase.started, phase.completed, phase.timerOffset, phase.completeTimer = false, false, 0, 0
    phase.creepPhase, phase.aiApproachSpeed = nil, nil
    for _, row in ipairs(rows) do if row.id == racer.vehId then M.clear({row}) end end
  end
  local stagedWrapper = type(originalStaged) == 'function' and function(value)
    if value == nil or value == data then
      for _, racer in pairs(data.racers or {}) do
        if not racer.isFinished and not racer.vehicleRemoved and racer.currentPhase == 1
          and racer.phases and racer.phases[1].completed and staged(racer) == false then reset(racer) end
      end
    end
    return originalStaged(value)
  end
  local countdownWrapper = type(originalCountdown) == 'function' and function(phase, racer, dt)
    if data.racers and data.racers[racer.vehId] == racer and not phase.started and not racer.treeStarted then
      if not racer.isPlayable and racer.vehId ~= be:getPlayerVehicleID(0) then
        local stopped = staged(racer) == true and type(racer.vehSpeed) == 'number' and racer.vehSpeed <= .05
        local step = type(dt) == 'number' and dt == dt and math.max(0, math.min(dt, .05)) or 0
        settledFor[racer] = stopped and (settledFor[racer] or 0) + step or 0
      end
      local armed, invalid, rolling = false, false, false
      for _, other in pairs(data.racers) do
        if not other.isFinished and not other.vehicleRemoved then
          local current = other.phases and other.phases[other.currentPhase]
          armed = armed or other.treeStarted or other.timersStarted or current and (current.name == 'race' or current.name == 'countdown' and current.started)
          invalid = invalid or staged(other) == false
          rolling = rolling or not other.isPlayable and other.vehId ~= be:getPlayerVehicleID(0)
            and (settledFor[other] or 0) < .2
        end
      end
      if not armed and invalid then
        for _, other in pairs(data.racers) do if not other.isFinished and not other.vehicleRemoved then reset(other) end end
        return
      end
      M.update(rows, data)
      if not armed and rolling then return end
    end
    local starting = not phase.started
    local result = originalCountdown(phase, racer, dt)
    if starting and phase.started then
      for _, row in ipairs(rows) do
        if row.id == racer.vehId and row.stagingHoldRacer == racer then
          local vehicle = be:getObjectByID(row.id)
          if vehicle then vehicle:queueLuaCommand("if overhaulMotorsportStagingHold then overhaulMotorsportStagingHold.updateGFX() end") end
        end
      end
    end
    return result
  end
  if stagedWrapper then handler.areAllRacersStaged = stagedWrapper end
  if countdownWrapper then handler.countdown = countdownWrapper end
  return function()
    M.clear(rows)
    if stagedWrapper and handler.areAllRacersStaged == stagedWrapper then handler.areAllRacersStaged = originalStaged end
    if countdownWrapper and handler.countdown == countdownWrapper then handler.countdown = originalCountdown end
  end
end
return M
