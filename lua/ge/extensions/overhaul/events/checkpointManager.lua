-- Checkpoint triggers, marker colors and expected-checkpoint state for the active race.
-- Read marker primitives, route locking, checkpoint lifecycle and session hooks.
local M = {}

M.dependencies = { "overhaul_events_session" }

local function getSanctionedRacing()
  return overhaul_events_fre_sanctionedRacing
end
local instance = require("overhaul/lib/events/course/checkpointManager").create({exports = M, getSanctionedRacing = getSanctionedRacing})

function M.onFreeroamSessionStarted(payload)
  if not payload or not payload.checkpointRoad then return end
  local sessionRaceName = payload.raceName
  local subjectID = payload.subjectID
  local racePayload = payload.race
  if not racePayload then return end

  local session = overhaul_events_session
  local processRoad = overhaul_events_roadCheckpoints
  local circuitRaceAi = overhaul_events_circuitRaceAi
  local competitiveTrackFlow = overhaul_events_competitiveTrackFlow
  local trackFlowState = competitiveTrackFlow and competitiveTrackFlow.trackFlowState
  local competitiveCircuit = competitiveTrackFlow and competitiveTrackFlow.raceUsesSanctionedParkingStaging
    and competitiveTrackFlow.raceUsesSanctionedParkingStaging(sessionRaceName)

  circuitRaceAi.resetForRaceBegin()
  processRoad.reset()
  processRoad.setStationaryTimeout(racePayload.timeout)
  local checkpointRows, alternateCheckpointRows = processRoad.getCheckpoints(racePayload)
  local sanctionedCircuit, routeOpts, sanctionedRacing = instance.prepareSessionCheckpointRoutes(racePayload, sessionRaceName, competitiveCircuit)
  M.createCheckpoints(checkpointRows, alternateCheckpointRows, nil, routeOpts)
  circuitRaceAi.setWaypointsFromCheckpoints(checkpointRows, alternateCheckpointRows)

  session.isLoop = processRoad.isLoop()
  session.currCheckpoint = 0
  session.checkpointsHit = 0

  local useAlt = (
    competitiveCircuit
    and trackFlowState
    and trackFlowState.useAltRoute == true
    and trackFlowState.inTrackFlowContext
  ) or false
  if sanctionedCircuit and sanctionedRacing and sanctionedRacing.isSanctionedCircuitRaceUseAltRoute then
    useAlt = sanctionedRacing.isSanctionedCircuitRaceUseAltRoute()
  end
  session.mAltRoute = useAlt
  M.setAltRoute(useAlt)
  local totalCp = M.calculateTotalCheckpoints()
  session.totalCheckpoints = totalCp
  session.currentExpectedCheckpoint = M.enableCheckpoint(0, useAlt)

  local aiRacers = overhaul_events_aiRacers
  if aiRacers and aiRacers.getSpawnedVehicleIds and aiRacers.releaseAndDrive then
    local raceForAi = (useAlt and racePayload.altRoute and racePayload.altRoute.checkpointRoad) and racePayload.altRoute
      or racePayload
    circuitRaceAi.setupAfterAiSpawn(sessionRaceName, subjectID, totalCp, racePayload, raceForAi)
  end

  overhaul_events_raceSession.showFreeroamRaceHud()
end

function M.onFreeroamSessionExiting(payload)
  if not payload or not payload.checkpointRoad then return end
  overhaul_events_circuitRaceAi.clearAll()
  M.removeCheckpoints()
end

function M.onExtensionLoaded() end

return M
