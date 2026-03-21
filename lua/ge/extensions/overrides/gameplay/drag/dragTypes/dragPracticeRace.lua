-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {
  "gameplay_drag_general",
  "gameplay_drag_utils"
}

local dGeneral, dUtils
local dragData
local logTag = ""
local freeroamEvents = require("gameplay/events/freeroamEvents")
local freeroamUtils = require("gameplay/events/freeroam/utils")
local raceSession
local freeroamSession
local hasActivityStarted = false
local function onExtensionLoaded()
  dGeneral = gameplay_drag_general
  dUtils = gameplay_drag_utils
  raceSession = gameplay_events_freeroam_raceSession
  freeroamSession = gameplay_events_freeroam_session
end

local function resetDragRace()
  if raceSession then
    raceSession.endDragPracticeFreeroamHud()
  end
  if not dragData then return end

  gameplay_drag_general.resetDragRace()

  hasActivityStarted = false
  -- Refresh dragData reference after reset
  dragData = dGeneral.getData()
end

local function startActivity()
  dragData = dGeneral.getData()

  if not dragData then
    log('E', logTag, 'No drag race data found')
    return
  end

  dragData.isStarted = true
  hasActivityStarted = dragData.isStarted

  local dials = {}
  if dragData.racers then
    for _,racer in pairs(dragData.racers) do
      table.insert(dials, {vehId = racer.vehId, dial = 0})
    end
  end
  dUtils.setDialsData(dials)

  if raceSession and dragData.racers then
    for _, racer in pairs(dragData.racers) do
      if racer.isPlayable then
        raceSession.beginDragPracticeFreeroamHud(racer.vehId)
        break
      end
    end
  end
end

local dqTimer = 0
local function onUpdate(dtReal, dtSim, dtRaw)
  if hasActivityStarted then
    if not dragData then
      log('E', logTag, 'No drag data found!')
      return
      end
    if not dragData.racers then
      log('E', logTag, 'There is no racers in the drag data.')
      return
    end

    for vehId, racer in pairs(dragData.racers) do
      if racer.isFinished then
        dragData.isCompleted = true
        resetDragRace()
        hasActivityStarted = false
        return
      end
      dUtils.updateRacer(racer)

      local phase = racer.phases[racer.currentPhase]
      dUtils[phase.name](phase, racer, dtSim)

      if racer.isPlayable and phase.name == "race" and racer.timersStarted and freeroamSession then
        freeroamSession.in_race_time = racer.timers.timer.value or 0
        local spd = racer.vehSpeed * freeroamSession.speedUnit
        if spd > freeroamSession.maxSpeed then
          freeroamSession.maxSpeed = spd
        end
      end

      if phase.completed and not racer.isFinished then
        log('I', logTag, 'Racer: '.. racer.vehId ..' completed phase: '.. phase.name)
        if phase.name == "stage" then
          if not raceSession or not raceSession.isRaceHudShown() then
            freeroamUtils.displayStagedMessage(racer.vehId, "drag")
          end
        elseif phase.name == "countdown" then
          freeroamUtils.saveAndSetTrafficAmount(0)
          if raceSession and raceSession.isRaceHudShown() then
            raceSession.beginDragPracticeFreeroamRace(racer.vehId)
          else
            freeroamUtils.displayStartMessage("drag")
          end
        elseif phase.name == "race" then
          if racer.timers.time_1_4.value and racer.timers.time_1_4.value > 0 then
            freeroamEvents.payoutDragRace("drag", racer.timers.time_1_4.value, racer.vehSpeed * 2.2369362921, vehId)
          end
          freeroamUtils.restoreTrafficAmount()
        end
        dUtils.changeRacerPhase(racer)
      end

      if racer.isDesqualified then
        dqTimer = dqTimer + dtSim
        if dqTimer > 3 then
          dqTimer = 0
          resetDragRace()
          hasActivityStarted = false
          return
        end
      end

      if not dUtils.isRacerInsideBoundary(racer) then
        resetDragRace()
        hasActivityStarted = false
        return
      end
    end
  end
end




--PUBLIC INTERFACE
M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.startActivity = startActivity
M.resetDragRace = resetDragRace

M.jumpDescualifiedDrag = function ()

end

return M
