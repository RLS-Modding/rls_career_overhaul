-- Dyno recovery owns displacement confirmation, route-loss grace and the pull watchdog.
-- The facade forwards router events; pulls owns service cleanup/resume, setup restores the build.
-- Thresholds come from activities/dyno.json; all runtime state belongs to this session load.
local lib = {}

function lib.create(inputs)
  local parts, state, session = inputs.parts, inputs.dynoState, inputs.dynoSession

  local function restoreDisplacedVehicle(dt)
    if not session.active or session.phase == "starting" or session.phase == "leaving"
      or state.restoreRequest or state.restoreFailed or not session.inventoryId then
      state.displacedAge = nil
      return
    end
    local id = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(session.inventoryId)
    local veh = id and getObjectByID(id)
    if not parts.vehicle.isDisplacedFromDyno(veh) then
      state.displacedAge = nil
      return
    end
    state.displacedAge = (state.displacedAge or 0) + dt
    if state.displacedAge < inputs.getRecoveryConfig().displacedConfirmSeconds then return end
    state.displacedAge = nil
    if session.serviceOpen then
      -- Cleanup may respawn a tuning preview before its asynchronous resume reply.
      state.serviceDisplacedTransform = state.serviceDisplacedTransform or parts.vehicle.captureVehicleTransform(veh)
      parts.pulls.closeSessionService()
      return
    end
    parts.vehicle.stopVehiclePullExtension(veh)
    session.statusText = "Restoring your vehicle."
    parts.setup.finishSessionRestore(parts.vehicle.captureVehicleTransform(veh))
  end

  local function onTeleportedToGarage(_, veh)
    if not state.restorePaused or not session.active then return end
    -- safeTeleport can defer the live position cache until the next physics step.
    -- Use the placement strategy's destination while physics is held.
    state.serviceDisplacedTransform = state.garageTowTransform or parts.vehicle.captureVehicleTransform(veh)
    if session.serviceOpen then
      parts.pulls.closeSessionService()
    else
      parts.vehicle.stopVehiclePullExtension(veh)
      parts.setup.finishSessionRestore(state.serviceDisplacedTransform)
    end
  end

  local function onUiChangedState(name)
    if not session.active or not session.serviceOpen or not name then return end
    state.serviceRouteInitialized = true
    local gameplay = ui_menuManager and ui_menuManager.getGameplayRoute and ui_menuManager.getGameplayRoute()
    state.serviceGameplayRoute = name == "play" or name == gameplay
    if not state.serviceGameplayRoute then
      state.serviceRouteSeen, state.serviceIdleAge = true, nil
    end
  end

  local function beginService()
    state.serviceRouteSeen, state.serviceIdleAge, state.serviceGameplayRoute = nil, nil, nil
    state.serviceDisplacedTransform = nil
    state.serviceRouteInitialized = nil
  end

  local function resumeClosedService(dt)
    if not session.active or not session.serviceOpen or state.restoreRequest then
      state.serviceRouteSeen, state.serviceIdleAge, state.serviceGameplayRoute = nil, nil, nil
      return
    end
    -- Seed once for a service that refused to navigate; subsequent changes are events.
    if not state.serviceRouteInitialized then
      state.serviceRouteInitialized = true
      if ui_router and ui_router.getCurrent then
        local ok, entry = pcall(ui_router.getCurrent)
        local name = ok and type(entry) == "table" and type(entry.resolved) == "table" and entry.resolved.name
        if name then onUiChangedState(name) end
      end
    end
    if not state.serviceGameplayRoute then return end
    local config = inputs.getRecoveryConfig()
    state.serviceIdleAge = (state.serviceIdleAge or 0) + dt
    if state.serviceIdleAge < (state.serviceRouteSeen and config.serviceReturnSeconds or config.serviceOpenGraceSeconds) then return end
    state.serviceRouteSeen, state.serviceIdleAge = nil, nil
    -- The service owns previews, pending respawns and the eventual resume callback.
    -- A refusal/pending discard must retain that ownership; never force a resume after it.
    parts.pulls.closeSessionService()
  end

  local function abortStalledPull(dtSim)
    local pull = session.pullState
    if not session.active or session.phase ~= "pulling" or not pull then return end
    pull.watchdogAge = (pull.watchdogAge or 0) + math.max(tonumber(dtSim) or 0, 0)
    if pull.watchdogAge < inputs.getRecoveryConfig().pullWatchdogSimSeconds then return end
    local veh = session.sessionVehicleId and getObjectByID(session.sessionVehicleId)
    if veh then parts.vehicle.stopVehiclePullExtension(veh) end
    parts.pulls.onPullFinished({pullId = pull.pullId, measurementComplete = false,
      pullQuality = "warning", qualityFlags = {"pullInterrupted"}, endReason = "watchdog",
      acceptedSampleCount = pull.acceptedSampleCount, rejectedSampleCount = pull.rejectedSampleCount,
      liveSample = pull.liveSample, curve = {}})
  end

  return {onTeleportedToGarage = onTeleportedToGarage, beginService = beginService, onUiChangedState = onUiChangedState, onUpdate = function(dtReal, dtSim)
    local dt = math.max(tonumber(dtReal) or 0, 0)
    parts.setup.tickRestore(dt)
    restoreDisplacedVehicle(dt)
    resumeClosedService(dt)
    abortStalledPull(dtSim)
  end}
end

return lib
