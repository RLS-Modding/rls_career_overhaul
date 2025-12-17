-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = ""
local dragData

local addFrameHistoryDebug = {
  reactionTime = true,
}

local function refreshDragData()
  if gameplay_drag_general then
    dragData = gameplay_drag_general.getData()
  else
    dragData = nil
  end
end

local function onExtensionLoaded()
  refreshDragData()
  M.reset()
end

local function reset()
  refreshDragData()
  if not dragData or not dragData.racers then return end
  for _, racer in pairs(dragData.racers) do
    racer.timersStarted = false
    for timerId,t in pairs(racer.timers) do
      if t.type ~= "dialTimer" then
        t.value = 0
        if addFrameHistoryDebug[timerId] then
          t.frameHistory = {}
        end
        if t.isSet ~= nil then
          t.isSet = false
        end
      end
    end
  end
end
M.reset = reset


local function velocityInAllUnits(speed)
  return string.format("%0.2fmph | %0.2fkm/h", speed * 2.23694, speed * 3.6)
end

local function onUpdate(dtReal, dtSim, dtRaw)
  refreshDragData()
  if not dragData or not dragData.racers or dragData.isCompleted then return end
  for _, racer in pairs(dragData.racers) do
    if not racer.timersStarted then goto continue end

    local timers = racer.timers
    local timerValue = timers.timer.value --0 first frame

    if gameplay_drag_utils then
      local distanceFromOrigin = racer.currentDistanceFromOrigin
      local prevDistance = racer.previousDistanceFromOrigin or distanceFromOrigin
      timerValue = timerValue + dtSim -- dtsim is 0.01
      timers.timer.value = timerValue

      local reactionTimeJustSet = false

      for timerName, timer in pairs(timers) do
        if addFrameHistoryDebug[timerName] and not timer.isSet and timer.type == "distanceTimer" then
          --print(string.format("Tracking times for racer: %d for timer: %s", racer.vehId, timerName))
          timer.frameHistory[#timer.frameHistory+1] = string.format("Racer: %d Frame %d: %0.5fs after start. Distance: %0.4fm (before: %0.4fm). Frame duration: %0.5fs", racer.vehId, #timer.frameHistory+1, timerValue, distanceFromOrigin, prevDistance, dtSim)
        end

        if timer.distance and not timer.isSet and distanceFromOrigin >= timer.distance then
          local t = inverseLerp(prevDistance, distanceFromOrigin, timer.distance)

          if timer.type == "distanceTimer" then
            timer.value = timerValue - (1 - t) * dtSim
            timer.isSet = true

            if timerName == "reactionTime" then
              reactionTimeJustSet = true
            end
          elseif timer.type == "velocity" then
            timer.value = lerp(racer.prevSpeed, racer.vehSpeed, t)
            timer.isSet = true
          end
          if addFrameHistoryDebug[timerName] and timer.type == "distanceTimer" then
            timer.frameHistory[#timer.frameHistory+1] = string.format("Racer: %d Went over threshold at %0.5fs (%d%% of this frames duration plus the previous frames) (so between frame %d and %d)", racer.vehId, timer.value, t*100, #timer.frameHistory-1, #timer.frameHistory)
            -- for _, frame in pairs(timer.frameHistory) do
            -- end
          end
        end
        if timer.type == "timeToVelocity" and not timer.isSet and racer.vehSpeed > timer.velocity then
          timer.value = timerValue
          timer.isSet = true
        end
        if racer.phases[racer.currentPhase].name == "emergencyStop" and racer.phases[racer.currentPhase].started and timer.type == "brakingG" and not timer.isSet then
          if not timer.emergencyStopTime then
            timer.emergencyStopTime = timerValue
          end
          -- check if the vehicle has been braking for more than 0.4 seconds
          if (timerValue - timer.emergencyStopTime > 0.4) and not timer.startTime then
            timer.startTime = timerValue
            timer.startDistance = distanceFromOrigin
            timer.startSpeed = racer.vehSpeed
          elseif timer.startTime and ((timerValue - timer.startTime > timer.deltaTime) or racer.vehSpeed < 0.1) then
            local actualDeltaTime = timerValue - timer.startTime
            local currentSpeed = racer.vehSpeed
            local deltaSpeed = currentSpeed - timer.startSpeed
            local deceleration = -deltaSpeed / actualDeltaTime -- Negative since we want deceleration to be positive
            timer.isSet = true
          end
        end
      end

      if reactionTimeJustSet then
        timers.timer.value = timers.timer.value - timers.reactionTime.value
        timerValue = 0
      end

      racer.previousDistanceFromOrigin = distanceFromOrigin
    end

    ::continue::
  end
end

local function preStageStarted()
end

local function dragRaceStarted(vehId)
  refreshDragData()
  if not dragData or not dragData.racers or not dragData.racers[vehId] then
    return
  end
  dragData.racers[vehId].timersStarted = true
end

local function resetDragRaceValues()
  reset()
end

--HOOKS
M.preStageStarted = preStageStarted
M.dragRaceStarted = dragRaceStarted
M.resetDragRaceValues = resetDragRaceValues

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded

return M