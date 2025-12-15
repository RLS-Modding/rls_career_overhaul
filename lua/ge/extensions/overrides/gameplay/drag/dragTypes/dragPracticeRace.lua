-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"gameplay_drag_general", "gameplay_drag_utils"}

local dGeneral, dUtils
local dragData
local logTag = ""
local freeroamEvents = require("gameplay/events/freeroamEvents")
local freeroamUtils = require("gameplay/events/freeroam/utils")
local hasActivityStarted = false
local dqTimer = 0
local clearDelayTimer = 0
local shouldClearAfterFinish = false

local function clear()
  dragData = nil
  hasActivityStarted = false
  dqTimer = 0
  clearDelayTimer = 0
  shouldClearAfterFinish = false
end

local function onExtensionLoaded()
  dGeneral = gameplay_drag_general
  dUtils = gameplay_drag_utils
  clear()
end

local function resetDragRace()
  if not dragData then return end

  gameplay_drag_general.resetDragRace()

  hasActivityStarted = false
  dqTimer = 0
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
    for _, racer in pairs(dragData.racers) do
      table.insert(dials, {vehId = racer.vehId, dial = 0})
    end
  end
  dUtils.setDialsData(dials)
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if shouldClearAfterFinish then
    clearDelayTimer = clearDelayTimer + dtSim
    if clearDelayTimer >= 1.0 then
      shouldClearAfterFinish = false
      clearDelayTimer = 0
      gameplay_drag_general.clearDragData()
      return
    end
  end

  if hasActivityStarted then
    if not dragData then
      log('E', logTag, 'No drag data found!')
      return
    end
    if not dragData.racers then
      log('E', logTag, 'There is no racers in the drag data.')
      return
    end

    -- Check if any racer is disqualified first
    local hasDisqualifiedRacer = false
    for vehId, racer in pairs(dragData.racers) do
      if racer.isDesqualified then
        hasDisqualifiedRacer = true
        break
      end
    end

    -- Reset timer if no racer is disqualified
    if not hasDisqualifiedRacer then
      dqTimer = 0
    end

    for vehId, racer in pairs(dragData.racers) do
      if racer.isFinished then
        dragData.isCompleted = true

        gameplay_drag_general.resetDragRace()
        hasActivityStarted = false
        dqTimer = 0

        local context = gameplay_drag_general.getGameplayContext()
        if context == "freeroam" then
          shouldClearAfterFinish = true
          clearDelayTimer = 0
        end
        return
      end
      dUtils.updateRacer(racer)

      local phase = racer.phases[racer.currentPhase]
      dUtils[phase.name](phase, racer, dtSim)

      if phase.completed and not racer.isFinished then
        log('I', logTag, 'Racer: '.. racer.vehId ..' completed phase: '.. phase.name)
        if phase.name == "stage" then
          freeroamUtils.displayStagedMessage(racer.vehId, "drag")
        elseif phase.name == "countdown" then
          freeroamUtils.displayStartMessage("drag")
          freeroamUtils.saveAndSetTrafficAmount(0)
        elseif phase.name == "race" then
          if racer.timers.time_1_4.value and racer.timers.time_1_4.value > 0 then
            freeroamEvents.payoutDragRace("drag", racer.timers.time_1_4.value, racer.vehSpeed * 2.2369362921, vehId)
          end
          freeroamUtils.restoreTrafficAmount()
        end
        dUtils.changeRacerPhase(racer)
      end

      if not dUtils.isRacerInsideBoundary(racer) then
        gameplay_drag_general.resetDragRace()
        hasActivityStarted = false
        dqTimer = 0
        return
      end
    end

    -- Handle disqualification timer after processing all racers
    if hasDisqualifiedRacer then
      dqTimer = dqTimer + dtSim
      if dqTimer > 3 then
        dqTimer = 0
        dragData.isCompleted = true

        gameplay_drag_general.resetDragRace()
        hasActivityStarted = false

        local context = gameplay_drag_general.getGameplayContext()
        if context == "freeroam" then
          shouldClearAfterFinish = true
          clearDelayTimer = 0
        end
        return
      end
    end
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.startActivity = startActivity
M.resetDragRace = resetDragRace

M.jumpDescualifiedDrag = function()
end

return M