-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- GE-callable API (also queued as ai.* after GE replaces the stock AI instance):
-- setMode(mode), setSpeedMode(speedMode), setSpeed(speed), setAvoidCars(v), driveInLane(v),
-- setTargetObjectID(id), setPullOver(val), setAggression(v), setAggressionMode(aggrmode),
-- driveUsingPath(arg), setState(newState), reset(), setVehicleDebugMode(newMode),
-- setParameters(data), setStopPoint(plan, dist, args), beginDerbyRecovery(reason).
-- Path/settings tables follow the stock AI shapes; factory parts live in overhaul/ai/.
-- Read state/bindings, target/mode helpers, reset/path actions, then the exported API.
-- Fork of stock lua/vehicle/ai.lua (BeamNG 0.40).

-- Owns the vehicle AI instance and its public mode/settings API.
-- Factories bind route, racing, traffic and steering code to this load's state.
local M = {}
local geCallback = require('vehicle/overhaul/geCallback')
M.mode = 'disabled' -- this is the main mode
M.manualTargetName = nil
M.debugMode = 'off'
M.speedMode = nil
M.routeSpeed = nil
M.extAggression = 0.3
M.cutOffDrivability = 0
M.driveInLaneFlag = 'off'
M.extAvoidCars = 'auto'

-- [[ STORE FREQUENTLY USED FUNCTIONS IN UPVALUES ]] --
local aiDebugDraw = require('aiDebugDraw')
local buffer = require("string.buffer")
local max, min, abs, sqrt, square = math.max, math.min, math.abs, math.sqrt, square
local tableInsert, tableRemove, tableConcat = table.insert, table.remove, table.concat
local resetTmpVec3, getTmpVec3 = resetTmpVec3, getTmpVec3

-- [[ Simulation time step]] --
local aiState = {}

-- [[ ENVIRONMENT VARIABLES ]] --
local g = obj:getGravity() -- standard gravity is negative
local gravityDir = vec3(0, 0, sign2(g))
g = max(1e-30, abs(g)) -- prevent divivion by 0 gravity

-- [[ PERFORMANCE RELATED ]] --
aiState.aggression = 1

-- [[ AI DATA: POSITION, CONTROL, STATE ]] --
local ego = {
  pos = obj:getFrontPosition(),
  dirVec = obj:getDirectionVector(),
  prevDirVec = obj:getDirectionVector(),
  upVec = obj:getDirectionVectorUp(),
  rightVec = vec3(),
  width = nil,
  length = nil,
  wheelBase = nil,
  currentSegment = {},
  vel = vec3(obj:getSmoothRefVelocityXYZ()),
  speed = vec3(obj:getSmoothRefVelocityXYZ()):length(),
  staticFrictionCoef = 1,
  lowTargetSpeedVal = 0.24,
  race_dT_min = 0.1,
  race_dT_max = 0.3,
  race_d = 4, -- distance thredshold, unless my distance from vehicle ahead is greater than this, I'll want to go faster than him
  race_time_gap = 0.3,
  race_catchAgg = 1,
  race_brakeAgg = 0
}

local throttleAccModel = newLineFitting(3, 0.3, -0.1, nil, 0.05, nil)
local throttleAccModelSmoother = newTemporalSmoothingNonLinear(1e30, 1, 1)
local targetSpeedDifSmoother = newTemporalSmoothingNonLinear(1e300, 4, 0)
local targetSpeedSmoother = newTemporalSmoothingNonLinear(10, 10, ego.speed)
local egoDeviationSmoother = newTemporalSmoothing(1)
local smoothTcs = newTemporalSmoothingNonLinear(0.4, 0.9, 1)
local throttleSmoother = newTemporalSmoothing(1e30, 0.2)

local internalState = {
  changePlanTimer = 0,
  egoCannotMoveTime = 0,
  egoForceGoFrontTime = 0,
  road = 'onroad',
  crash = {time = 0, maneuver = 0, dir = vec3(), pos = vec3()},
  derby = {
    recoveryTimer = 0,
    recoveryDuration = 0,
    recoveryDirection = -1,
    recoverySteer = 0,
    recoveryCooldown = 0,
    recoveryAttempts = 0,
    reason = nil,
    crashes = nil,
    crashObjID = -1,
  },
  chaseData = {playerState = nil, playerStoppedTimer = 0, playerRoad = nil, driveAhead = false, targetSpeed = nil}
}

local twt = {
  state = 0,
  dirState = {0, 0}, -- direction, steer
  posTable = {vec3(), vec3(), vec3(), vec3()},
  dirTable = {vec3(), vec3(), vec3(), vec3()},
  minRay = "",
  rayMins = {math.huge, math.huge, math.huge, math.huge, math.huge, math.huge, math.huge, math.huge}, --clockwise beginning from corner front left
  minRayCoefs = {0, 0, 0, 0, 0, 0, 0, 0}, -- clockwise as above
  blueNoiseCoefs = {0, 0, 0, 0, 0, 0, 0, 0},
  biasedCoefs = {0, 0, 0, 0, 0, 0, 0, 0},
  blueNoiseRR = 0,
  sampleCounter = 0, -- for starting scan, to give some time for precision
  targetSpeed = 0,
  OBBinRange = {},
  RRT = {1,1,1,2,1,2,2,2,2,2,2,3,2,3,3,3,3,3,3,4,3,4,4,4,4,4,4,1,4,1,1,1},
  speedSmoother = newTemporalSmoothingNonLinear(1000, 0.25),
  steerSmoother = newTemporalSmoothingNonLinear(2)
}

twt.reset = function()
  twt.state = 0
  twt.dirState[1], twt.dirState[2] = 0, 0
  twt.minRay = nil
  for i = 1, #twt.rayMins do twt.rayMins[i] = math.huge end
  for i = 1, #twt.blueNoiseCoefs do twt.blueNoiseCoefs[i] = 0 end
  twt.sampleCounter = 0
  twt.targetSpeed = 0
  twt.speedSmoother:set(0)
  twt.steerSmoother:set(0)
end

local forces = {}
local planNodeStack = table.new(25, 0)
local lastCommand = {steering = 0, throttle = 0, brake = 0, parkingbrake = 0}

local opt = {driveInLaneFlag = false, racing = false, aggressionMode = nil, avoidCars = 'on', enableFastPhysicsforTraffic = true}

-- [[ TRAFFIC ]] --
local trafficStates = {}
aiState.trafficPathState = {}

local traffic = {
  objects = {},
  Rfl_fun = function(v) return clamp((v + 10) * 3, 60, 200) end,
  blueNoiseRR = 0,
  cache = {}, -- cache of vehicles in the map
  collision = {}, -- cache of vehicles colliding with one plan segment
  sideCache = {}, -- cache of vehicles on the side
  newCachedVNext = {}, -- cache of vehicles added to at least one plan segment (at the current frame)
  newCachedV = {}, -- cache vehicles added to at least one plan segment (at the previous frame)
  totalCachedVehicles = 0, -- total number of cached vehicles
  filtered = true,
  vdraw = false,
}

local raceAltPlan = {
  runAltPlans = true,
  hystTime = 0.1,
  normIdx = function(idx)
    if idx == nil then return 0 end
    return idx
  end,
}

-- [[ OPPONENT DATA ]] --

-- [[ SETTINGS, PARAMETERS, AUXILIARY DATA ]] --
local MIN_PLAN_COUNT = 3
aiState.validateInput = nop
local routeLoop = { loopPath = nil, noOfLaps = nil }
aiState.scriptai = nil
local recover = {recoverOnCrash = false, recoverTimer = 0, _recoverOnCrash = false}
local slotTrafficTarget = {pos = vec3(), speed = 0, age = math.huge}
------------------------------
local function saveGearboxMode()
  if aiState.restoreGearboxMode then return end
  aiState.restoreGearboxMode = electrics.values.gearboxMode
end
local function restoreSavedGearboxMode()
  if not aiState.restoreGearboxMode then return end
  if not controller.mainController then return end
  controller.mainController.setGearboxMode(aiState.restoreGearboxMode)
  aiState.restoreGearboxMode = nil
end

-- Both extension hooks and global ai.updateGFX can tick this AI.
-- A table avoids LuaJIT's 200-local limit.
local gfxGuard = {lastSimTime = nil, scriptFn = nop}
function gfxGuard.isRepeatCall()
  local simTime = obj:getSimTime()
  if simTime == gfxGuard.lastSimTime then return true end
  gfxGuard.lastSimTime = simTime
  return false
end
function gfxGuard.scriptUpdateGFX(dtGFX)
  if M.updateGFX ~= gfxGuard.scriptUpdateGFX or gfxGuard.isRepeatCall() then return end
  gfxGuard.scriptFn(dtGFX)
end
function gfxGuard.setScriptUpdateGFX()
  gfxGuard.scriptFn = aiState.scriptai.updateGFX
  M.updateGFX = gfxGuard.scriptFn == nop and nop or gfxGuard.scriptUpdateGFX
end

local configurationPart = require('vehicle/overhaul/ai/configuration').create({
  M = M,
  aiState = aiState,
  ego = ego,
  targetSpeedSmoother = targetSpeedSmoother,
  internalState = internalState,
  lastCommand = lastCommand,
  opt = opt,
  trafficStates = trafficStates,
})

local steeringPart = require('vehicle/overhaul/ai/steering').create({
  M = M,
  geCallback = geCallback,
  square = square,
  getTmpVec3 = getTmpVec3,
  aiState = aiState,
  g = g,
  gravityDir = gravityDir,
  ego = ego,
  egoDeviationSmoother = egoDeviationSmoother,
  smoothTcs = smoothTcs,
  throttleSmoother = throttleSmoother,
  internalState = internalState,
  twt = twt,
  lastCommand = lastCommand,
  opt = opt,
})
local driveCar = steeringPart.driveCar
local populateOBBinRange = steeringPart.populateOBBinRange
local castRay = steeringPart.castRay
local driveToTarget = steeringPart.driveToTarget

local lanesPart = require('vehicle/overhaul/ai/lanes').create({
  buffer = buffer,
  square = square,
  tableInsert = tableInsert,
  getTmpVec3 = getTmpVec3,
  aiState = aiState,
  g = g,
  ego = ego,
  planNodeStack = planNodeStack,
})

local routeNodesPart = require('vehicle/overhaul/ai/routeNodes').create({
  M = M,
  square = square,
  tableRemove = tableRemove,
  getTmpVec3 = getTmpVec3,
  aiState = aiState,
  ego = ego,
  twt = twt,
  planNodeStack = planNodeStack,
  opt = opt,
  routeLoop = routeLoop,
  updatePlanLen = lanesPart.updatePlanLen,
  numOfLanesInDirection = lanesPart.numOfLanesInDirection,
  getEdgeLaneConfig = lanesPart.getEdgeLaneConfig,
  laneRange = lanesPart.laneRange,
  getLaneRangeFromLane = lanesPart.getLaneRangeFromLane,
  processNodeIncomingLanes = lanesPart.processNodeIncomingLanes,
  getBestLane = lanesPart.getBestLane,
})

local function inCurvature(v1, v2)
  --[[
    Given three points A, B, C (with AB being the vector from A to B), the curvature (= 1 / radius)
    of the circle going through them is:

    curvature = 2 * (AB x BC) / ( |AB| * |BC| * |CA| ) =>
              = 2 * |AB| * |BC| * Sin(th) / ( |AB| * |BC| * |CA| ) =>
              = 2 * (+/-) * sqrt ( 1 - Cos^2(th) ) / |CA| =>
              = 2 * (+/-) sqrt [ ( 1 - Cos^2(th) ) / |CA|^2 ) ] -- This is an sqrt optimization step

    In the calculation below the (+/-) which indicates the turning direction (direction of AB x BC) has been dropped
  --]]

  -- v1 and v2 vector components
  local v1x, v1y, v1z, v2x, v2y, v2z = v1.x, v1.y, v1.z, v2.x, v2.y, v2.z

  local v1Sqlen, v2Sqlen = v1x * v1x + v1y * v1y + v1z * v1z, v2x * v2x + v2y * v2y + v2z * v2z
  local dot12 = v1x * v2x + v1y * v2y + v1z * v2z
  local cosSq = min(1, dot12 * dot12 / max(1e-30, v1Sqlen * v2Sqlen))

  if dot12 < 0 then -- angle between the two segments is > 90 deg
    local minDsq = min(v1Sqlen, v2Sqlen)
    local maxDsq = minDsq / max(1e-30, cosSq)
    if max(v1Sqlen, v2Sqlen) > (minDsq + maxDsq) * 0.5 then
      if v1Sqlen > v2Sqlen then
        -- swap v1 and v2
        v1x, v1y, v1z, v2x, v2y, v2z = v2x, v2y, v2z, v1x, v1y, v1z
        v1Sqlen, v2Sqlen = v2Sqlen, v1Sqlen
      end
      local s = sqrt(0.5 * (minDsq + maxDsq) / max(1e-30, v2Sqlen))
      v2x, v2y, v2z = s * v2x, s * v2y, s * v2z
    end
  end

  return 2 * sqrt((1 - cosSq) / max(1e-30, square(v1x + v2x) + square(v1y + v2y) + square(v1z + v2z))) -- the denominator is v1:squaredLength(-v2)
end

-- ********* FUNCTIONS FOR SPEED PROFILE GENERATION ********* --

local speedPlanningPart = require('vehicle/overhaul/ai/speedPlanning').create({
  M = M,
  square = square,
  tableInsert = tableInsert,
  tableRemove = tableRemove,
  getTmpVec3 = getTmpVec3,
  aiState = aiState,
  g = g,
  ego = ego,
  opt = opt,
  traffic = traffic,
  setGetObjectBoundingBox = configurationPart.setGetObjectBoundingBox,
  calculateTarget = lanesPart.calculateTarget,
  updatePlanLen = lanesPart.updatePlanLen,
  openLaneToLaneRange = lanesPart.openLaneToLaneRange,
  getNewNode = routeNodesPart.getNewNode,
})


local racePlanningPart = require('vehicle/overhaul/ai/racePlanning').create({
  M = M,
  square = square,
  tableInsert = tableInsert,
  getTmpVec3 = getTmpVec3,
  aiState = aiState,
  g = g,
  gravityDir = gravityDir,
  ego = ego,
  internalState = internalState,
  twt = twt,
  forces = forces,
  opt = opt,
  traffic = traffic,
  raceAltPlan = raceAltPlan,
  MIN_PLAN_COUNT = MIN_PLAN_COUNT,
  routeLoop = routeLoop,
  calculateTarget = lanesPart.calculateTarget,
  updatePlanLen = lanesPart.updatePlanLen,
  openLaneToLaneRange = lanesPart.openLaneToLaneRange,
  numOfLanesInDirection = lanesPart.numOfLanesInDirection,
  getEdgeLaneConfig = lanesPart.getEdgeLaneConfig,
  laneRange = lanesPart.laneRange,
  getLaneRangeFromLane = lanesPart.getLaneRangeFromLane,
  getBestLane = lanesPart.getBestLane,
  buildNextRoute = routeNodesPart.buildNextRoute,
  mergePathPrefix = routeNodesPart.mergePathPrefix,
  uniformPlanErrorDistribution = routeNodesPart.uniformPlanErrorDistribution,
  createNewRoute = routeNodesPart.createNewRoute,
  inCurvature = inCurvature,
  solveForwardSpeedProfile = speedPlanningPart.solveForwardSpeedProfile,
  solveBackwardSpeedProfile = speedPlanningPart.solveBackwardSpeedProfile,
  calculateTrafficTargetSpeed = speedPlanningPart.calculateTrafficTargetSpeed,
  copyNode = speedPlanningPart.copyNode,
  updateLateralAvoidance = speedPlanningPart.updateLateralAvoidance,
  densifyPlan = speedPlanningPart.densifyPlan,
})
local planRaceRouteAhead = racePlanningPart.planRaceRouteAhead

local routePlanningPart = require('vehicle/overhaul/ai/routePlanning').create({
  M = M,
  square = square,
  tableInsert = tableInsert,
  tableRemove = tableRemove,
  getTmpVec3 = getTmpVec3,
  aiState = aiState,
  g = g,
  gravityDir = gravityDir,
  ego = ego,
  internalState = internalState,
  twt = twt,
  forces = forces,
  opt = opt,
  trafficStates = trafficStates,
  traffic = traffic,
  MIN_PLAN_COUNT = MIN_PLAN_COUNT,
  routeLoop = routeLoop,
  calculateTarget = lanesPart.calculateTarget,
  getMinPlanLen = lanesPart.getMinPlanLen,
  updatePlanLen = lanesPart.updatePlanLen,
  openLaneToLaneRange = lanesPart.openLaneToLaneRange,
  openPlanLanesToLaneRange = lanesPart.openPlanLanesToLaneRange,
  numOfLanesInDirection = lanesPart.numOfLanesInDirection,
  getEdgeLaneConfig = lanesPart.getEdgeLaneConfig,
  roadNaturalContinuation = lanesPart.roadNaturalContinuation,
  laneRange = lanesPart.laneRange,
  getLaneRangeFromLane = lanesPart.getLaneRangeFromLane,
  getBestLane = lanesPart.getBestLane,
  buildNextRoute = routeNodesPart.buildNextRoute,
  mergePathPrefix = routeNodesPart.mergePathPrefix,
  createNewRoute = routeNodesPart.createNewRoute,
  isVehicleStopped = routeNodesPart.isVehicleStopped,
  inCurvature = inCurvature,
  solveForwardSpeedProfile = speedPlanningPart.solveForwardSpeedProfile,
  solveBackwardSpeedProfile = speedPlanningPart.solveBackwardSpeedProfile,
  updatePlanBestRange = speedPlanningPart.updatePlanBestRange,
  densifyPlan = speedPlanningPart.densifyPlan,
})
local planAhead = routePlanningPart.planAhead

local navigationPart = require('vehicle/overhaul/ai/navigation').create({
  M = M,
  square = square,
  tableInsert = tableInsert,
  tableRemove = tableRemove,
  aiState = aiState,
  g = g,
  ego = ego,
  internalState = internalState,
  opt = opt,
  routeLoop = routeLoop,
  stateChanged = configurationPart.stateChanged,
  setSpeed = configurationPart.setSpeed,
  setSpeedMode = configurationPart.setSpeedMode,
  setAggressionInternal = configurationPart.setAggressionInternal,
  setAggressionExternal = configurationPart.setAggressionExternal,
  resetAggression = configurationPart.resetAggression,
  resetInternalStates = configurationPart.resetInternalStates,
  resetParameters = configurationPart.resetParameters,
  setParameters = configurationPart.setParameters,
  targetsCompatible = lanesPart.targetsCompatible,
  getMinPlanLen = lanesPart.getMinPlanLen,
  pickAiWp = lanesPart.pickAiWp,
  pathExtend = lanesPart.pathExtend,
  getPathLen = lanesPart.getPathLen,
  waypointInPath = lanesPart.waypointInPath,
  createNewRoute = routeNodesPart.createNewRoute,
  planAhead = planAhead,
})

local trafficPart = require('vehicle/overhaul/ai/traffic').create({
  M = M,
  square = square,
  tableInsert = tableInsert,
  tableRemove = tableRemove,
  getTmpVec3 = getTmpVec3,
  aiState = aiState,
  g = g,
  gravityDir = gravityDir,
  ego = ego,
  internalState = internalState,
  trafficStates = trafficStates,
  recover = recover,
  getObjectBoundingBox = configurationPart.getObjectBoundingBox,
  driveCar = driveCar,
  getLastNodeWithinDistance = lanesPart.getLastNodeWithinDistance,
  targetsCompatible = lanesPart.targetsCompatible,
  getMinPlanLen = lanesPart.getMinPlanLen,
  pickAiWp = lanesPart.pickAiWp,
  pathExtend = lanesPart.pathExtend,
  getPathLen = lanesPart.getPathLen,
  laneChange = lanesPart.laneChange,
  setStopPoint = lanesPart.setStopPoint,
  numOfLanesInDirection = lanesPart.numOfLanesInDirection,
  getEdgeLaneConfig = lanesPart.getEdgeLaneConfig,
  roadNaturalContinuation = lanesPart.roadNaturalContinuation,
  isVehicleStopped = routeNodesPart.isVehicleStopped,
  planAhead = planAhead,
})
local trafficActions = trafficPart.trafficActions
local trafficPlan = trafficPart.trafficPlan

local frameUpdatePart = require('vehicle/overhaul/ai/frameUpdate').create({
  M = M,
  square = square,
  tableConcat = tableConcat,
  resetTmpVec3 = resetTmpVec3,
  getTmpVec3 = getTmpVec3,
  aiState = aiState,
  g = g,
  gravityDir = gravityDir,
  ego = ego,
  throttleAccModel = throttleAccModel,
  throttleAccModelSmoother = throttleAccModelSmoother,
  targetSpeedDifSmoother = targetSpeedDifSmoother,
  internalState = internalState,
  twt = twt,
  lastCommand = lastCommand,
  opt = opt,
  trafficStates = trafficStates,
  raceAltPlan = raceAltPlan,
  routeLoop = routeLoop,
  recover = recover,
  slotTrafficTarget = slotTrafficTarget,
  restoreSavedGearboxMode = restoreSavedGearboxMode,
  gfxGuard = gfxGuard,
  dataLogger = configurationPart.dataLogger,
  startStopDataLog = configurationPart.startStopDataLog,
  getObjectBoundingBox = configurationPart.getObjectBoundingBox,
  aistatus = configurationPart.aistatus,
  stateChanged = configurationPart.stateChanged,
  setAggressionInternal = configurationPart.setAggressionInternal,
  updatePlayerData = configurationPart.updatePlayerData,
  driveCar = driveCar,
  driveToTarget = driveToTarget,
  targetsCompatible = lanesPart.targetsCompatible,
  getMinPlanLen = lanesPart.getMinPlanLen,
  getPathLen = lanesPart.getPathLen,
  offsetPlan = speedPlanningPart.offsetPlan,
  copyPlan = speedPlanningPart.copyPlan,
  planRaceRouteAhead = planRaceRouteAhead,
  planAhead = planAhead,
  resetMapAndRoute = navigationPart.resetMapAndRoute,
  getMapEdges = navigationPart.getMapEdges,
  newManualPath = navigationPart.newManualPath,
  setScriptedPath = navigationPart.setScriptedPath,
  fleePlan = navigationPart.fleePlan,
  chasePlan = navigationPart.chasePlan,
  trafficActions = trafficActions,
  trafficPlan = trafficPlan,
})
local updateGFX = frameUpdatePart.updateGFX

local function setAvoidCars(v)
  M.extAvoidCars = v
  if M.extAvoidCars == 'off' or M.extAvoidCars == 'on' then
    opt.avoidCars = M.extAvoidCars
  else
    opt.avoidCars = M.mode == 'manual' and 'off' or 'on'
  end
  configurationPart.stateChanged()
end

local function driveInLane(v)
  if v == 'on' then
    M.driveInLaneFlag = 'on'
    opt.driveInLaneFlag = true
  else
    M.driveInLaneFlag = 'off'
    opt.driveInLaneFlag = false
  end
  configurationPart.stateChanged()
end

local function setVehicleDebugMode(newMode)
  tableMerge(M, newMode)
  aiDebugDraw.onDebugModeChanged(M.debugMode)
  if M.debugMode ~= 'off' then
    aiDebugDraw.enable()
  else
    aiDebugDraw.disable()
  end
end

local function setMode(mode)
  if tableSizeC(wheels.wheels) == 0 then return end
  local previousMode = M.mode
  if mode ~= nil then
    if M.mode ~= mode then -- new AI mode is not the same as the old one
      obj:queueGameEngineLua('onAiModeChange('..objectId..', "'..mode..'")')
    end
    M.mode = mode
  end

  if M.extAvoidCars == 'off' or M.extAvoidCars == 'on' then
    opt.avoidCars = M.extAvoidCars
  else
    opt.avoidCars = ((M.mode == 'manual' or M.mode == 'slotTraffic') and 'off' or 'on')
  end

  if M.mode ~= 'script' then
    if M.mode ~= 'disabled' and M.mode ~= 'stop' then
      navigationPart.resetMapAndRoute()

      if M.mode ~= 'slotTraffic' then mapmgr.requestMap() end
      M.updateGFX = updateGFX
      targetSpeedDifSmoother:set(0)
      targetSpeedSmoother:set(ego.speed)

      if controller.mainController then
        if previousMode == 'disabled' then
          saveGearboxMode()
        end
        controller.mainController.setGearboxMode('arcade')
      end

      ego.wheelBase = configurationPart.calculateWheelBase()

      if M.mode == 'flee' or M.mode == 'chase' or M.mode == 'follow' then
        configurationPart.setAggressionMode('rubberBand')
      end

      if M.mode == 'traffic' then
        configurationPart.setSpeedMode('legal')
        driveInLane('on')
        speedPlanningPart.setTractionModel(1)
        configurationPart.setParameters({minStTargetDist = 2})
        speedPlanningPart.setSpeedProfileMode('Back')
        if opt.enableFastPhysicsforTraffic then
          obj:setSelfCollisionMode(2)
          obj:setAerodynamicsMode(2)
        else
          obj:setSelfCollisionMode(1)
          obj:setAerodynamicsMode(1)
        end
      else
        obj:setSelfCollisionMode(1)
        obj:setAerodynamicsMode(1)
      end
    end

    if M.mode == 'disabled' then
      driveCar(0, 0, 0, 0)
      M.updateGFX = nop
      aiState.currentRoute = nil
      restoreSavedGearboxMode()
    end

    configurationPart.stateChanged()
    sounds.updateObjType()
  end

  aiDebugDraw.reset()
end

local function setSlotTrafficTarget(x, y, z, speed)
  slotTrafficTarget.pos:set(x or 0, y or 0, z or 0)
  slotTrafficTarget.speed = max(0, tonumber(speed) or 0)
  slotTrafficTarget.age = 0
  if M.mode ~= 'slotTraffic' then setMode('slotTraffic') end
end

local function setRecoverOnCrash(val)
  recover.recoverOnCrash = val
end

local function toggleTrafficMode()
  if M.mode == "traffic" then
    setMode("disabled")
    setRecoverOnCrash(false)
  else
    setMode("traffic")
    setRecoverOnCrash(true)
  end
end

local function reset() -- called when the user pressed I
  M.manualTargetName = nil
  configurationPart.resetInternalStates()

  throttleSmoother:set(0)
  throttleAccModelSmoother:set(0)
  smoothTcs:set(1)

  if M.mode ~= 'disabled' then
    driveCar(0, 0, 0, 0)
    setMode() -- some scenarios don't work if this is changed to setMode('disabled')
  end
  configurationPart.stateChanged()

  if configurationPart.dataLogger.logData ~= nop then
    configurationPart.startStopDataLog()
  end
end

local function setState(newState)
  if tableSizeC(wheels.wheels) == 0 then return end

  if newState.mode and newState.mode ~= M.mode then -- new AI mode is not the same as the old one
    obj:queueGameEngineLua('onAiModeChange('..objectId..', "'..newState.mode..'")')
  end

  local mode = M.mode
  tableMerge(M, newState)
  configurationPart.setAggressionExternal(M.extAggression)

  -- after a reload (cntr-R) vehicle should be left with handbrake engaged if mode is disabled
  -- preserve initial state of vehicle controls (handbrake engaged) if current mode and new mode are both 'disabled'
  if not (mode == 'disabled' and M.mode == 'disabled') then
    setMode()
  end

  setVehicleDebugMode(M)
  configurationPart.setTargetObjectID(M.targetObjectID)
  configurationPart.stateChanged()
end

local function setTarget(wp)
  M.manualTargetName = wp
  aiState.validateInput = navigationPart.validateUserInput
  aiState.wpList = {wp}
end

local function setPath(path)
  aiState.manualPath = path
  aiState.validateInput = navigationPart.validateUserInput
end

local function driveUsingPath(arg)
  --[[ At least one argument of either path or wpTargetList or script must be specified. All other arguments are optional.

  * path: A sequence of waypoint names that form a path by themselves to be followed in the order provided.
  * wpTargetList: A sequence of waypoint names to be used as succesive targets ex. wpTargetList = {'wp1', 'wp2'}.
                  Between any two consequitive waypoints a shortest path route will be followed.
  * script: A sequence of positions from a user-defined trajectory. For each node/position we have
            * mandatory properties:
              * x, y, z global coordinates of the corresponding node
            * optional properties:
              * r, the width of the path built using the scripted trajectory at the corresponding node
              * vl, roadSpeedLimit for the corresponding node. If this value is specified and routeSpeedMode is set to 'legal', vl will act as an upper bound for the speed profile
              * v, speed value for the corresponding node. If this value is specified the ai is forced to reach it at the corresponding node, skipping awareness and routeSpeedLimit (if they are enabled)

  -- Optional Arguments --
  * wpSpeeds: Type: (key/value pairs, key: "node_name", value: speed, number in m/s)
              Define target speeds for individual waypoints. The ai will try to meet this speed when at the given waypoint.
  * noOfLaps: Type: number. Default value: nil
              The number of laps if the path is a loop. If not defined, the ai will just follow the succesion of waypoints once.
  * routeSpeed: A speed in m/s. To be used in tandem with "routeSpeedMode".
                Type: number
  * routeSpeedMode: Values: 'limit': the ai will not go above the 'routeSpeed' defined by routeSpeed.
                            'set': the ai will try to always go at the speed defined by "routeSpeed".
  * driveInLane: Values: 'on' (anything else is considered off/inactive)
                 When 'on' the ai will keep on the correct side of the road on two way roads.
                 This also affects pathFinding in that when this option is active ai paths will traverse roads in the legal direction if posibble.
                 Default: inactive
  * aggression: Value: 0.3 - 1. The aggression value with which the ai will drive the route.
                At 1 the ai will drive at the limit of traction. A value of 0.3 would be considered normal every day driving, going shopping etc.
                Default: 0.3
  * avoidCars: Values: 'on' / 'off'.  When 'on' the ai will be aware of (avoid crashing into) other vehicles on the map. Default is 'off'
  * examples:
  ai.driveUsingPath{ wpTargetList = {'wp1', 'wp10'}, driveInLane = 'on', avoidCars = 'on', routeSpeed = 35, routeSpeedMode = 'limit', wpSpeeds = {wp1 = 10, wp2 = 40}, aggression = 0.3}
  In the above example the speeds set for wp1 and wp2 will take precedence over "routeSpeed" for the specified nodes.
  --]]

  if (arg.wpTargetList == nil and arg.path == nil and arg.script == nil) or
    (type(arg.wpTargetList) ~= 'table' and type(arg.path) ~= 'table' and type(arg.script) ~= 'table') or
    (arg.wpSpeeds ~= nil and type(arg.wpSpeeds) ~= 'table') or
    (arg.noOfLaps ~= nil and type(arg.noOfLaps) ~= 'number') or
    (arg.routeSpeed ~= nil and type(arg.routeSpeed) ~= 'number') or
    (arg.routeSpeedMode ~= nil and type(arg.routeSpeedMode) ~= 'string') or
    (arg.driveInLane ~= nil and type(arg.driveInLane) ~= 'string') or
    (arg.aggression ~= nil and type(arg.aggression) ~= 'number')
  then
    return
  end

  if arg.script then
    -- Set vehicle position and orientation at the start of the path
    -- Get initial position and orientation of vehicle at start of path (possibly time offset and/or time delayed)
    local script = arg.script
    local dir, up, pos
    if script[1].dir then
      -- vehicle initial orientation vectors exist

      dir = vec3(script[1].dir)
      up = vec3(script[1].up or mapmgr.surfaceNormalBelow(vec3(script[1])))

      local frontPosRelOrig = obj:getOriginalFrontPositionRelative() -- original relative front position in the vehicle coordinate system (left, back, up)
      local vx = dir * -frontPosRelOrig.y
      local vz = up * frontPosRelOrig.z
      local vy = dir:cross(up) * -frontPosRelOrig.x
      pos = vec3(script[1]) - vx - vz - vy
      local dH = require('scriptai').wheelToGroundDist(pos, dir, up)
      pos:setAdd(dH * up)
    else
      -- vehicle initial orientation vectors don't exist
      -- estimate vehicle orientation vectors from path and ground normal

      local p1 = vec3(script[1])
      local p1z0 = p1:z0()
      local scriptPosi = vec3()
      local k
      for i = 2, #script do
        scriptPosi:set(script[i].x, script[i].y, 0)
        if p1z0:squaredDistance(scriptPosi) > 0.2 * 0.2 then
          k = i
          break
        end
      end

      if k then
        local p2 = vec3(script[k])
        dir = p2 - p1; dir:normalize()
        up = mapmgr.surfaceNormalBelow(p1)

        local frontPosRelOrig = obj:getOriginalFrontPositionRelative() -- original relative front position in the vehicle coordinate system (left, back, up)
        local vx = dir * -frontPosRelOrig.y
        local vz = up * frontPosRelOrig.z
        local vy = dir:cross(up) * -frontPosRelOrig.x
        pos = p1 - vx - vz - vy
        local dH = require('scriptai').wheelToGroundDist(pos, dir, up)
        pos:setAdd(dH * up)
      end
    end

    if dir then
      local rot = quatFromDir(dir:cross(up):cross(up), up)
      obj:queueGameEngineLua(
        "getObjectByID(" .. objectId .. "):resetBrokenFlexMesh();" ..
        "vehicleSetPositionRotation(" .. objectId .. "," .. pos.x .. "," .. pos.y .. "," .. pos.z .. "," .. rot.x .. "," .. rot.y .. "," .. rot.z .. "," .. rot.w .. ")"
      )

      mapmgr.setCustomMap() -- nils mapmgr.mapData
      M.mode = 'manual'
      configurationPart.stateChanged()
      routeLoop.noOfLaps = max(arg.noOfLaps or 1, 1)
      local pathMap = require('graphpath').newGraphpath() -- create a dummy graph

      local scrCount = #arg.script
      if routeLoop.noOfLaps > 1 and arg.script[scrCount].x == arg.script[1].x and arg.script[scrCount].y == arg.script[1].y and arg.script[scrCount].z == arg.script[1].z then
        routeLoop.loopPath = true
      end

      local path = table.new(scrCount, 0)
      aiState.speedProfile = table.new(0, scrCount)
      local radius = obj:getInitialWidth()

      -- set the graph node positions and widths and create the path array and speed profile data
      for i = 1, scrCount - (routeLoop.loopPath and 1 or 0) do -- avoid adding the last point if the scripts loops
        local node = 'wp_'..tostring(i)
        pathMap:setPointPositionRadius(node, vec3(arg.script[i].x, arg.script[i].y, arg.script[i].z), arg.script[i].r or radius)
        path[i] = node
        aiState.speedProfile[node] = arg.script[i].v -- TODO: This is a problem with a looping path for first/last node speed setting
      end

      if routeLoop.loopPath then
        tableInsert(path, path[1])
      end

      -- add the nodes and edges to the dummy graph
      for i = 1, scrCount - 1 do
        local n1id, n2id = path[i], path[i+1]
        pathMap:uniEdge(n1id, n2id, pathMap.positions[n1id]:distance(pathMap.positions[n2id]), 1, arg.script[i].vl or 100, nil, false)
      end

      aiState.scriptData = deepcopy(arg)
      aiState.scriptData.mapData = pathMap
      aiState.scriptData.path = path
      aiState.scriptData.speedProfile = aiState.speedProfile
      aiState.scriptData.noOfLaps = routeLoop.noOfLaps
      aiState.scriptData.loopPath = routeLoop.loopPath
    end
  else
    setState({mode = 'manual'})

    configurationPart.setParameters({ -- setParameters calls tableMerge so the nil guards are not really needed
      driveStyle = arg.driveStyle or 'default',
      staticFrictionCoefMult = arg.staticFrictionCoefMult,
      lookAheadKv = max(0.1, arg.lookAheadKv or aiState.parameters.lookAheadKv),
      understeerThrottleControl = arg.understeerThrottleControl,
      oversteerThrottleControl = arg.oversteerThrottleControl,
      throttleTcs = arg.throttleTcs,
      abBrakeControl = arg.abBrakeControl,
      underSteerBrakeControl = arg.underSteerBrakeControl,
      throttleKp = arg.throttleKp,
      targetSpeedSmootherRate = arg.targetSpeedSmootherRate,
      turnForceCoef = arg.turnForceCoef,
      springForceIntegratorDispLim = arg.springForceIntegratorDispLim
    })

    routeLoop.noOfLaps = max(arg.noOfLaps or 1, 1)
    aiState.wpList = arg.wpTargetList
    aiState.manualPath = arg.path
    aiState.validateInput = navigationPart.validateUserInput
    opt.avoidCars = arg.avoidCars or 'off'

    if routeLoop.noOfLaps > 1 and ((aiState.wpList and aiState.wpList[2] and aiState.wpList[1] == aiState.wpList[#aiState.wpList]) or (aiState.manualPath and aiState.manualPath[2] and aiState.manualPath[1] == aiState.manualPath[#aiState.manualPath])) then
      routeLoop.loopPath = true
    end

    aiState.speedProfile = arg.wpSpeeds or {}
    configurationPart.setSpeed(arg.routeSpeed)
    configurationPart.setSpeedMode(arg.routeSpeedMode)

    driveInLane(arg.driveInLane)

    configurationPart.setAggressionExternal(arg.aggression)
    configurationPart.stateChanged()
  end
end

M.driveUsingPathWithTraffic = function(arg)
  -- Helper function to easily enable manual traffic mode
  -- This combines destination-oriented driving with traffic rule following
  if not arg then
    return
  end

  -- Set up the parameters with traffic-friendly defaults
  local trafficArgs = {
    wpTargetList = arg.wpTargetList,
    path = arg.path,
    script = arg.script,
    wpSpeeds = arg.wpSpeeds,
    noOfLaps = arg.noOfLaps,
    routeSpeed = arg.routeSpeed,
    routeSpeedMode = arg.routeSpeedMode,
    driveInLane = arg.driveInLane or 'on', -- Default to staying in lanes
    aggression = arg.aggression or 0.3, -- Default to conservative driving
    avoidCars = arg.avoidCars or 'on', -- Default to avoiding cars
    driveStyle = arg.driveStyle,
    staticFrictionCoefMult = arg.staticFrictionCoefMult,
    lookAheadKv = arg.lookAheadKv,
    understeerThrottleControl = arg.understeerThrottleControl,
    oversteerThrottleControl = arg.oversteerThrottleControl,
    throttleTcs = arg.throttleTcs,
    abBrakeControl = arg.abBrakeControl,
    underSteerBrakeControl = arg.underSteerBrakeControl
  }

  -- Use the regular driveUsingPath function to set up the route
  driveUsingPath(trafficArgs)

  -- Then switch to manual traffic mode
  M.mode = 'manualTraffic'
  configurationPart.stateChanged()
end

local function spanMap(cutOffDrivability)
  M.cutOffDrivability = cutOffDrivability or 0
  setState({mode = 'span'})
  configurationPart.stateChanged()
end

local function setCutOffDrivability(drivability)
  M.cutOffDrivability = drivability or 0
  configurationPart.stateChanged()
end

local function onDeserialized(v)
  setState(v)
  configurationPart.stateChanged()
end

local function dumpCurrentRoute()
  dump(aiState.currentRoute)
end

local function getParameters()
  return aiState.parameters
end

local function startRecording(recordSpeed)
  M.mode = 'script'
  aiState.scriptai = require("scriptai")
  aiState.scriptai.startRecording(recordSpeed)
  gfxGuard.setScriptUpdateGFX()
end

local function stopRecording()
  M.mode = 'disabled'
  aiState.scriptai = require("scriptai")
  local script = aiState.scriptai.stopRecording()
  gfxGuard.setScriptUpdateGFX()
  return script
end

local function startFollowing(...)
  local script = ...
  if script.path then
    script = script.path
  end
  if script[1] and script[1].v then
    driveUsingPath({script = script})
  else
    M.mode = 'script'
    aiState.scriptai = require("scriptai")
    aiState.scriptai.startFollowing(...)
    gfxGuard.setScriptUpdateGFX()
  end
end

local function scriptStop(...)
  M.mode = 'disabled'
  aiState.scriptai = require("scriptai")
  aiState.scriptai.scriptStop(...)
  gfxGuard.setScriptUpdateGFX()
end

local function scriptState()
  aiState.scriptai = require("scriptai")
  return aiState.scriptai.scriptState()
end

local function setScriptDebugMode(mode)
  aiState.scriptai = require("scriptai")
  if mode == nil or mode == 'off' then
    M.debugMode = 'all'
    aiDebugDraw.disable()
    return
  end

  aiDebugDraw.enable()
  aiState.scriptai.debugMode = mode
end

local function isDriving()
  return M.updateGFX == updateGFX or (aiState.scriptai ~= nil and aiState.scriptai.isDriving())
end

local function bindAiDebugContext()
  aiDebugDraw.init({
    ego = ego,
    twt = twt,
    lastCommand = lastCommand,
    player = function() return aiState.player end,
    getCurrentRoute = function() return aiState.currentRoute end,
    getMapData = function() return aiState.mapData end,
    getScriptai = function() return aiState.scriptai end,
    roadNaturalContinuation = lanesPart.roadNaturalContinuation,
    castRay = castRay,
    populateOBBinRange = populateOBBinRange,
  })
end

aiDebugDraw.setContextBinder(bindAiDebugContext)
bindAiDebugContext()

-- public interface
M.driveInLane = driveInLane
M.createPendingRoute = function()
  aiState.mapData = mapmgr.mapData
  ego.pos:set(obj:getFrontPositionXYZ())
  return navigationPart.createPendingRoute()
end
M.stateChanged = configurationPart.stateChanged
M.reset = reset
M.setMode = setMode
M.toggleTrafficMode = toggleTrafficMode
M.setAvoidCars = setAvoidCars
M.setSlotTrafficTarget = setSlotTrafficTarget
M.setTarget = setTarget
M.setPath = setPath
M.setSpeed = configurationPart.setSpeed
M.setSpeedMode = configurationPart.setSpeedMode
M.setParameters = configurationPart.setParameters
M.getParameters = getParameters
M.setVehicleDebugMode = setVehicleDebugMode
M.setState = setState
M.getState = configurationPart.getState
M.debugDraw = nop
M.driveUsingPath = driveUsingPath
M.setAggressionMode = configurationPart.setAggressionMode
M.setAggression = configurationPart.setAggressionExternal
M.onDeserialized = onDeserialized
M.setTargetObjectID = configurationPart.setTargetObjectID
M.laneChange = lanesPart.laneChange
M.setStopPoint = lanesPart.setStopPoint
M.dumpCurrentRoute = dumpCurrentRoute
M.spanMap = spanMap
M.setCutOffDrivability = setCutOffDrivability
M.isDriving = isDriving
M.startStopDataLog = configurationPart.startStopDataLog
M.setRecoverOnCrash = setRecoverOnCrash
M.getEdgeLaneConfig = lanesPart.getEdgeLaneConfig
M.setPullOver = navigationPart.setPullOver
M.roadNaturalContinuation = lanesPart.roadNaturalContinuation -- for debugging
M.saveGearboxMode = saveGearboxMode
M.restoreSavedGearboxMode = restoreSavedGearboxMode
M.resetLearning = nop

-- scriptai
M.startRecording = startRecording
M.stopRecording = stopRecording
M.startFollowing = startFollowing
M.stopFollowing = scriptStop
M.scriptStop = scriptStop
M.scriptState = scriptState
M.setScriptDebugMode = setScriptDebugMode
M.setTractionModel = speedPlanningPart.setTractionModel
M.setSpeedProfileMode = speedPlanningPart.setSpeedProfileMode
M.beginDerbyRecovery = internalState.derby.beginRecovery
M.getDerbyRecoveryState = function()
  return {
    timer = internalState.derby.recoveryTimer,
    cooldown = internalState.derby.recoveryCooldown,
    attempts = internalState.derby.recoveryAttempts,
    direction = internalState.derby.recoveryDirection,
    reason = internalState.derby.reason,
  }
end

return M
