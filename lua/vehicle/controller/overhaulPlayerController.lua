-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Owns the walking controller: movement input, fixed-step forces and animation state.
-- Read state/tuning, movement helpers, simulation updates, input actions, then the exported controller API.
-- player/controllerSeam.lua adapts this controller for the vehicle extension.
-- Fork of stock lua/vehicle/controller/playerController.lua (BeamNG 0.40).

--Purpose: Enables walking-mode movement for the unicycle-based player

local M = {}
-- RLS seam (vehicle/overhaul/player/controllerSeam.lua): stamina speed/jump multipliers, external
-- movement input for realistic walk-to-vehicle, the movement note for GE. Lines marked "RLS" differ from stock.
local rlsMove = require('vehicle/overhaul/player/controllerSeam').create()
--Mandatory controller parameters
M.type = "auxiliary" -- RLS: loaded beside stock playerController by overhaulPlayerControllerManager
M.defaultOrder = 500

M.fireEngineTemperature = 0
M.throttle = 0
M.brake = 0
M.clutchRatio = 0
-----

-- Locals for speed: this file runs every physics step.
local min = math.min
local max = math.max
local abs = math.abs
local acos = math.acos
local atan2 = math.atan2
local pi = math.pi
local twoPi = pi * 2

local stabilizationMaxForce
local yawMaxForce
local movementSpeedNormal
local movementSpeedSprint
local maxBallTorque
local ballPressureNormal
local ballPressureCrouch
local jumpForce
local jumpForceTime
local slipUsageCoef

local function applySpeedMultiplier() -- RLS
  if not rlsMove.hasSpeedBase() then return end
  local speedMult = rlsMove.speedMultiplier()
  movementSpeedNormal = rlsMove.scaledWalkingSpeed(speedMult)
  movementSpeedSprint = rlsMove.scaledSprintSpeed(speedMult)
  maxBallTorque = rlsMove.scaledBallTorque(speedMult)

  stabilizationMaxForce = rlsMove.scaledStabilizationForce(speedMult)
  yawMaxForce = rlsMove.scaledYawForce(speedMult)
end

local function applyJumpForceMultiplier() -- RLS
  local force = rlsMove.scaledJumpForce()
  if force == nil then return end
  jumpForce = force
end

local stabilizationNodes = {
  topCenter = 0,
  topFront = 0,
  topRear = 0,
  topLeft = 0,
  topRight = 0,
  bottomCenter = 0,
  bottomFront = 0,
  bottomRear = 0,
  bottomLeft = 0,
  bottomRight = 0
}

local stabilizationBeams = {
  bottomTop = 0,
  centerFront = 0,
  centerRear = 0,
  centerLeft = 0,
  centerRight = 0,
  frontLeft = 0,
  frontRight = 0,
  rearLeft = 0,
  rearRight = 0
}

local ballCenterNode = -1
local ballRadiusNode = -1

local ballNodes = {}
local ballGroundContactNodesNew = {}
local ballGroundContactNodesPast = {}
local ballCenterVelocity = vec3(0, 0, 0)
local ballBasedPlayerVelocity = vec3(0, 0, 0)
local ballTorqueSmoother = newTemporalSmoothing(10, 5)

local jumpForceTimer = 0

local lockBeams = {}
local isBallLocked = false
local ballLockStates = {unlocked = "unlocked", locking = "locking", locked = "locked"}
local ballLockState = ballLockStates.unlocked
local previousBallLockState = ballLockStates.unlocked
local ballLockRampTimer = 0

M.engineInfo = {
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  "manual",
  obj:getId(),
  0,
  0,
  1,
  0,
  0,
  0
}

local isFrozen = false

local debugVectors = {}
local cameraRotation = quat(0, 0, 0, 0)
local cameraRotationStandardVector = vec3(0, 1, 0)
local cameraRotationRightVector = vec3(1, 0, 0)
local walkVector = vec3(0, 0, 0)
local movementSpeedCoef = 0

local isTouchingWater = false
local isTouchingGround = false

local jumpCooldown = 0
local isCrouching = false
local isUnCrouching = false
local unCrouchingPressureRatio = 0

local stabilizationPIDs = {
  frontRear = newPIDParallel(2, 0.1, 0.3, -1, 1, 100, 50, -1, 1),
  leftRight = newPIDParallel(2, 0.1, 0.3, -1, 1, 100, 50, -1, 1),
  yawPosition = newPIDParallel(2, 0.0, 0.5, -1, 1)
}

local ballTorqueNodes = {}
local ballTorqueAxis = vec3(0, 0, 0)
local ballDesiredTorque = 0
local ballAVSmoother = newExponentialSmoothing(25)

--forces to be applied at physics step
--stabilization
local forceVectorFront = vec3()
local forceVectorLeft = vec3()
--yaw
local yawLeftForce = 0
local yawRightForce = 0

local particleRate = 0

local function debugDraw(focusPos)
  for _, v in pairs(debugVectors) do
    obj.debugDrawProxy:drawNodeVector3d(v.thickness or 0.05, v.cid, v.vector, v.color)
  end
end

local function nodeCollision(p)
  --take a look at physics particles and use the node and slip velocities to estimate a ball center velocity that is local to the unicycle
  local slipVelocity = vec3(p.slipVec)
  local nodeVelocity = vec3(p.nodeVel)
  ballBasedPlayerVelocity = ballCenterVelocity - nodeVelocity + (slipVelocity * slipUsageCoef)
  table.insert(ballGroundContactNodesNew, p.id1)
  particleRate = particleRate + 1
end

local function applyTorque(axis, node1, node2, node3, torque)
  obj:apply3nodeTorque(axis, torque, node1, node2, node3)
end

local function applyForceVector(node, forceVec)
  obj:applyForceVector(node, forceVec)
end

local function applyForce(node1, node2, force)
  obj:applyForce(node1, node2, force)
end

local function update(dt)
  --stabilization
  applyForceVector(stabilizationNodes.topCenter, forceVectorFront)
  applyForceVector(stabilizationNodes.bottomCenter, -forceVectorFront)

  applyForceVector(stabilizationNodes.topCenter, forceVectorLeft)
  applyForceVector(stabilizationNodes.bottomCenter, -forceVectorLeft)

  --yaw
  applyForce(stabilizationNodes.topFront, stabilizationNodes.topLeft, yawLeftForce)
  applyForce(stabilizationNodes.topRear, stabilizationNodes.topRight, yawLeftForce)
  applyForce(stabilizationNodes.topFront, stabilizationNodes.topRight, yawRightForce)
  applyForce(stabilizationNodes.topRear, stabilizationNodes.topLeft, yawRightForce)

  --propulsion
  applyTorque(ballTorqueAxis, ballTorqueNodes[0], ballTorqueNodes[1], ballTorqueNodes[2], ballDesiredTorque)

  --jumping
  if jumpForceTimer > 0 then
    jumpForceTimer = jumpForceTimer - dt

    --jump by "extending" the uniycycle in such a way that it propels away from the ground
    local vectorUp = obj:getBeamVectorFromNode(stabilizationBeams.bottomTop, stabilizationNodes.bottomCenter):normalized()
    --pull top of the unicycle up with a given force
    obj:applyForceVector(stabilizationNodes.topCenter, (vectorUp * jumpForce))

    --push down the ground-touching ball nodes with the overall same force, spread across all touching nodes
    if #ballGroundContactNodesPast > 0 then -- RLS: no contact nodes, no division by zero
      local ballNodeForce = jumpForce / #ballGroundContactNodesPast
      local ballNodeForceVector = (-vectorUp * ballNodeForce)
      for _, cid in ipairs(ballGroundContactNodesPast) do
        obj:applyForceVector(cid, ballNodeForceVector)
      end
    end
  end
end

local function setBallLock(locked)
  if locked == isBallLocked then
    return
  end
  isBallLocked = locked

  previousBallLockState = ballLockState
  ballLockState = locked and ballLockStates.locking or ballLockStates.unlocked
  if not locked then
    ballLockRampTimer = 0
  end
end

local function updateBallLock(dt)
  if ballLockState == previousBallLockState then
    return
  end

  local spring
  local damp
  if ballLockState == ballLockStates.locking then
    spring = 0
    damp = 400
    ballLockRampTimer = ballLockRampTimer + dt
    local rampTime = 0.4 + movementSpeedCoef * 0.3 -- 400ms when walking, 700ms when sprinting
    if ballLockRampTimer >= rampTime then
      previousBallLockState = ballLockStates.locking
      ballLockState = ballLockStates.locked
    end
  elseif ballLockState == ballLockStates.locked then
    spring = 100000
    damp = 100
    previousBallLockState = ballLockStates.locked
  else
    spring = 0
    damp = 0
    previousBallLockState = ballLockStates.unlocked
  end
  for _, cid in ipairs(lockBeams) do
    obj:setBeamLength(cid, obj:getBeamLength(cid))
    obj:setBeamSpringDamp(cid, spring, damp, -1, -1)
  end
end

local function updateFixedStep(dt)
  ballCenterVelocity = obj:getNodeVelocityVector(ballCenterNode)
  local enableStabilizationCoef = 1

  --actual up vector of the unicycle
  local vectorUp = obj:getBeamVectorFromNode(stabilizationBeams.bottomTop, stabilizationNodes.bottomCenter):normalized()

  local vectorTopLeft = obj:getBeamVectorFromNode(stabilizationBeams.centerLeft, stabilizationNodes.topCenter):normalized()
  local normalLeft = vectorTopLeft:cross(-vectorUp):normalized()
  local normalRight = normalLeft:cross(vectorUp):normalized()
  local targetVector = vec3(0, 0, 1)

  local projectedVertical = (targetVector - targetVector:dot(normalLeft) * normalLeft):normalized()
  local projectedHorizontal = (targetVector - targetVector:dot(normalRight) * normalRight):normalized()

  local angleHorizontal = acos(min(max(vectorUp:dot(projectedVertical), -1), 1))
  local horizontalAngleSign = sign(normalLeft:dot(vectorUp:cross(projectedVertical)))
  local angleVertical = acos(min(max(vectorUp:dot(projectedHorizontal), -1), 1))
  local verticalAngleSign = sign(normalRight:dot(vectorUp:cross(projectedHorizontal)))

  local frontRearAngle = angleVertical * verticalAngleSign
  local leftRightAngle = angleHorizontal * horizontalAngleSign

  local forceMultiplier = stabilizationMaxForce * enableStabilizationCoef
  local frontRearForceCoef = stabilizationPIDs.frontRear:get(-frontRearAngle, 0, dt)
  local leftRightForceCoef = stabilizationPIDs.leftRight:get(-leftRightAngle, 0, dt)

  forceVectorFront = obj:getNodesVector(stabilizationNodes.topCenter, stabilizationNodes.topFront):normalized() * frontRearForceCoef * forceMultiplier
  forceVectorLeft = obj:getNodesVector(stabilizationNodes.topCenter, stabilizationNodes.topLeft):normalized() * leftRightForceCoef * forceMultiplier

  ----------------
  ---Propulsion---
  ----------------
  local frozenCoef = isFrozen and 0 or 1
  local speedCoef, moveInput, worldSpaceMove = rlsMove.propulsionInput(movementSpeedCoef, walkVector) -- RLS: external move
  local desiredMovementSpeed = linearScale(speedCoef, 0, 1, movementSpeedNormal, movementSpeedSprint) * frozenCoef --0 movement speed when locked
  local guardedWalkVector = moveInput:z0() * frozenCoef --set this to zero if frozen to keep the ball locked
  if guardedWalkVector:length() > 1 then
    guardedWalkVector:normalize()
  end

  -- yaw-only look axes so pitch does not scale walk speed by cos(pitch)
  local cameraDirection = (cameraRotation * cameraRotationStandardVector):z0()
  if cameraDirection:length() > 1e-5 then
    cameraDirection:normalize()
  else
    cameraDirection = vec3(0, 1, 0)
  end
  local cameraRight = (cameraRotation * cameraRotationRightVector):z0()
  if cameraRight:length() > 1e-5 then
    cameraRight:normalize()
  else
    cameraRight = vec3(1, 0, 0)
  end
  local desiredMovementVector = (worldSpaceMove and guardedWalkVector or (cameraRight * guardedWalkVector.x + cameraDirection * guardedWalkVector.y)) * desiredMovementSpeed -- RLS
  local actualMovementVector = ballBasedPlayerVelocity:z0()
  local velocityError = desiredMovementVector - actualMovementVector
  local velocityErrorLength = ballTorqueSmoother:getUncapped(velocityError:length(), dt)

  if guardedWalkVector:length() > 0 then
    ballTorqueAxis = velocityError:cross(vectorUp)
    ballDesiredTorque = velocityErrorLength * maxBallTorque
    setBallLock(false)
  else
    ballTorqueAxis = cameraDirection:cross(vectorUp)
    ballDesiredTorque = 0
    setBallLock(true)
  end

  local ballAV = obj:get3nodeAngularVelocity(ballTorqueAxis, ballTorqueNodes[0], ballTorqueNodes[1], ballTorqueNodes[2])
  if isnan(ballAV) then
    ballAV = 0
    ballAVSmoother:set(0)
  else
    ballAV = ballAVSmoother:get(ballAV)
  end

  local ballRadius = obj:getNodesVector(ballCenterNode, ballRadiusNode):length()
  local maxBallAVAdjusted = desiredMovementSpeed / max(ballRadius, 0.01)
  local ballAVTorqueCoef = linearScale(ballAV, maxBallAVAdjusted, maxBallAVAdjusted + 1, 1, 0)
  ballDesiredTorque = ballDesiredTorque * ballAVTorqueCoef

  --yaw
  local meshDirection = obj:getBeamVectorFromNode(stabilizationBeams.centerFront, stabilizationNodes.topCenter):z0():normalized()
  --calculate angle between the two vectors
  local angleError = atan2(cameraDirection.y, cameraDirection.x) - atan2(meshDirection.y, meshDirection.x)
  --fix up the range to be [-pi, +pi]
  if angleError > pi then
    angleError = angleError - twoPi
  elseif angleError <= -pi then
    angleError = angleError + twoPi
  end

  local yawForceCoef = stabilizationPIDs.yawPosition:get(angleError, 0, dt)
  local yawLeftForceCoef = abs(min(yawForceCoef, 0))
  local yawRightForceCoef = abs(max(yawForceCoef, 0))
  local yawForceMultiplier = yawMaxForce * enableStabilizationCoef
  yawLeftForce = (yawLeftForceCoef + linearScale(yawRightForceCoef, 0, 0.01, 0.1, 0)) * yawForceMultiplier
  yawRightForce = (yawRightForceCoef + linearScale(yawLeftForceCoef, 0, 0.01, 0.1, 0)) * yawForceMultiplier

  local cameraLook = cameraRotation * cameraRotationStandardVector
  electrics.values.head_rotation = angleError
  electrics.values.head_tilt = cameraLook:dot(vectorUp)

  updateBallLock(dt)

  --table.insert(debugVectors, {cid = stabilizationNodes.topLeft, vector = vectorTopFrontLeft * yawLeftForce * 0.001, color = color(244, 93, 1, 255)})
  --table.insert(debugVectors, {cid = stabilizationNodes.topRight, vector = vectorTopRearRight * yawLeftForce * 0.001, color = color(244, 93, 1, 255)})
  --table.insert(debugVectors, {cid = stabilizationNodes.topRight, vector = vectorTopFrontRight * yawRightForce * 0.001, color = color(175, 18, 90, 255)})
  --table.insert(debugVectors, {cid = stabilizationNodes.topLeft, vector = vectorTopRearLeft * yawRightForce * 0.001, color = color(175, 18, 90, 255)})
end

local function updateGFX(dt)
  ballGroundContactNodesPast, ballGroundContactNodesNew = ballGroundContactNodesNew, ballGroundContactNodesPast
  table.clear(ballGroundContactNodesNew)

  if isUnCrouching then
    unCrouchingPressureRatio = min(unCrouchingPressureRatio + dt * 2, ballPressureNormal)
    obj:setGroupPressureRel(v.data.pressureGroups.ball, unCrouchingPressureRatio)
    if unCrouchingPressureRatio >= 1 then
      isUnCrouching = false
      isCrouching = false
    end
  end

  isTouchingWater = false
  isTouchingGround = false
  for nodeCid, _ in pairs(ballNodes) do
    isTouchingWater = isTouchingWater or obj:inWater(nodeCid)
    isTouchingGround = isTouchingGround or obj:isNodeColliding(nodeCid)
  end

  particleRate = particleRate / dt

  -- Any collision this frame supplies a relative-motion sample for training.
  -- The stock 100/s movement smoothing threshold drops real steps at 30 FPS.
  local validWalkingContact = isTouchingGround and particleRate > 0
  rlsMove.noteWalkingMotion(playerInfo.firstPlayerSeated, walkVector, isFrozen,
    validWalkingContact, ballCenterVelocity, ballBasedPlayerVelocity,
    max(movementSpeedNormal, movementSpeedSprint)) -- RLS

  if not isTouchingGround or particleRate < 100 then
    ballBasedPlayerVelocity = vec3(0, 0, 0) --ball based AV doesn't work in water, make sure to reset the measured value to 0
  end
  particleRate = 0

  jumpCooldown = max(jumpCooldown - dt, 0)

  electrics.values.gearboxMode = "none"
  electrics.values.freezeState = isFrozen

  rlsMove.noteMove(playerInfo.firstPlayerSeated, movementSpeedCoef, walkVector) -- RLS
end

local function walkLeftRightRaw(value)
  walkVector.x = value
end

local function walkLeftRight(value)
  walkVector.x = walkVector.x + value
end

local function walkUpDownRaw(value)
  walkVector.y = value
end

local function walkUpDown(value)
  walkVector.y = walkVector.y + value
end

local function setSpeed(value)
  movementSpeedCoef = value
end

local function toggleSpeed()
  movementSpeedCoef = 1 - movementSpeedCoef
end

local function jump(value)
  if jumpCooldown > 0 or isFrozen then
    return
  end

  if #ballGroundContactNodesPast > 0 or isTouchingGround then
    jumpForceTimer = jumpForceTime
    jumpCooldown = 0.5
  end
end

local function crouch(value)
  if isFrozen then
    return
  end

  if value < 0 then
    obj:setGroupPressureRel(v.data.pressureGroups["ball"], ballPressureCrouch)
    isCrouching = true
  elseif value > 0 then
    isUnCrouching = true
    unCrouchingPressureRatio = 0.5
  end
end

local function toggleCrouch()
  if isFrozen then
    return
  end

  isCrouching = not isCrouching
  crouch(isCrouching and -1 or 1)
end

local function setFreeze(mode)
  isFrozen = mode == 1
end

local function reset()
  isFrozen = false
  isBallLocked = false
  ballLockState = ballLockStates.unlocked
  previousBallLockState = ballLockStates.unlocked
  ballLockRampTimer = 0
  isTouchingGround = false
  isTouchingWater = false
  isCrouching = false
  isUnCrouching = false
  jumpCooldown = 0

  forceVectorFront = vec3()
  forceVectorLeft = vec3()

  yawLeftForce = 0
  yawRightForce = 0

  walkVector = vec3(0, 0, 0)
  rlsMove.clearExternalMove() -- RLS
  ballTorqueAxis = vec3(0, 0, 0)
  stabilizationPIDs.frontRear:reset()
  stabilizationPIDs.leftRight:reset()
  stabilizationPIDs.yawPosition:reset()
end

local function init(jbeamData)
  isCrouching = false
  isUnCrouching = false

  yawLeftForce = 0
  yawRightForce = 0

  movementSpeedNormal = jbeamData.movementSpeedNormal or 5
  movementSpeedSprint = jbeamData.movementSpeedSprint or 11
  maxBallTorque = jbeamData.maxBallTorque or 700
  stabilizationMaxForce = jbeamData.stabilizationMaxForce or 8000
  yawMaxForce = jbeamData.yawMaxForce or 200
  ballPressureNormal = jbeamData.ballPressureNormal or 1.0
  ballPressureCrouch = jbeamData.ballPressureCrouch or 0.5
  jumpForce = jbeamData.jumpForce or 50000
  jumpForceTime = jbeamData.jumpForceTime or 0.01
  slipUsageCoef = jbeamData.slipUsageCoef or 1

  rlsMove.captureBase(movementSpeedNormal, movementSpeedSprint, maxBallTorque, stabilizationMaxForce, yawMaxForce, jumpForce) -- RLS
  if rlsMove.speedMultiplierSet() then applySpeedMultiplier() end -- RLS
  if rlsMove.jumpMultiplierSet() then applyJumpForceMultiplier() end -- RLS

  stabilizationNodes.topCenter = jbeamData.stabilizationTopCenter
  stabilizationNodes.topFront = jbeamData.stabilizationTopFront
  stabilizationNodes.topRear = jbeamData.stabilizationTopRear
  stabilizationNodes.topLeft = jbeamData.stabilizationTopLeft
  stabilizationNodes.topRight = jbeamData.stabilizationTopRight

  stabilizationNodes.bottomCenter = jbeamData.stabilizationBottomCenter
  stabilizationNodes.bottomFront = jbeamData.stabilizationBottomFront
  stabilizationNodes.bottomRear = jbeamData.stabilizationBottomRear
  stabilizationNodes.bottomLeft = jbeamData.stabilizationBottomLeft
  stabilizationNodes.bottomRight = jbeamData.stabilizationBottomRight

  ballCenterNode = jbeamData.ballCenter

  for _, beam in pairs(v.data.beams) do
    if beam.tag == jbeamData.stabilizationBeamFront then
      stabilizationBeams.centerFront = beam.cid
    elseif beam.tag == jbeamData.stabilizationBeamRear then
      stabilizationBeams.centerRear = beam.cid
    elseif beam.tag == jbeamData.stabilizationBeamLeft then
      stabilizationBeams.centerLeft = beam.cid
    elseif beam.tag == jbeamData.stabilizationBeamRight then
      stabilizationBeams.centerRight = beam.cid
    elseif beam.tag == jbeamData.stabilizationBeamFrontLeft then
      stabilizationBeams.frontLeft = beam.cid
    elseif beam.tag == jbeamData.stabilizationBeamFrontRight then
      stabilizationBeams.frontRight = beam.cid
    elseif beam.tag == jbeamData.stabilizationBeamRearLeft then
      stabilizationBeams.rearLeft = beam.cid
    elseif beam.tag == jbeamData.stabilizationBeamRearRight then
      stabilizationBeams.rearRight = beam.cid
    elseif beam.tag == jbeamData.stabilizationBeamBottomTop then
      stabilizationBeams.bottomTop = beam.cid
    elseif beam.tag == "lockBeam" then
      table.insert(lockBeams, beam.cid)
    end
  end

  for _, node in pairs(v.data.nodes) do
    if node.tag == "ball" then
      ballNodes[node.cid] = true
      ballRadiusNode = node.cid
    end
    if node.name == "ib7" then
      ballTorqueNodes[0] = node.cid
    end
    if node.name == "ib2" then
      ballTorqueNodes[1] = node.cid
    end
    if node.name == "ib8" then
      ballTorqueNodes[2] = node.cid
    end
  end

  mapmgr.enableTracking()
  obj:setSleepingEnabled(false)
end

local function setCameraControlData(controlData)
  cameraRotation = controlData.cameraRotation
end

M.init = init
M.reset = reset
M.updateFixedStep = updateFixedStep
M.updateGFX = updateGFX
M.update = update

M.setAggressionOverride = nop
M.setDefaultForwardMode = nop

M.nodeCollision = nodeCollision

--Mandatory main controller API
M.shiftUp = nop
M.shiftDown = nop
M.shiftToGearIndex = nop
M.cycleGearboxModes = nop
M.setGearboxMode = nop
M.smartParkingBrake = nop
M.setStarter = nop
M.setEngineIgnition = nop
M.setFreeze = setFreeze
M.sendTorqueData = nop
M.vehicleActivated = nop
-------------------------------

M.debugDraw = debugDraw

M.setCameraControlData = setCameraControlData
M.setExternalMove = rlsMove.setExternalMove -- RLS
M.setExternalWorldMove = rlsMove.setExternalWorldMove -- RLS
M.jump = jump
M.walkLeftRightRaw = walkLeftRightRaw
M.walkLeftRight = walkLeftRight
M.walkUpDownRaw = walkUpDownRaw
M.walkUpDown = walkUpDown
M.setSpeedCoef = setSpeed
M.toggleSpeedCoef = toggleSpeed
M.crouch = crouch
M.toggleCrouch = toggleCrouch

-- RLS: stamina multipliers and the control state overhaulPlayerControllerManager replays on restore
local function updateSpeed(speedMult)
  rlsMove.setSpeedMultiplier(speedMult)
  applySpeedMultiplier()
end

local function updateJumpForce(jumpForceMult)
  rlsMove.setJumpForceMultiplier(jumpForceMult)
  applyJumpForceMultiplier()
end

M.updateSpeed = updateSpeed
M.setMovementSpeedMultiplier = updateSpeed
M.updateJumpForce = updateJumpForce
M.setJumpForceMultiplier = updateJumpForce

M.getControlState = function()
  return {x = walkVector.x, y = walkVector.y, speed = movementSpeedCoef, frozen = isFrozen,
    crouching = isCrouching, cameraRotation = cameraRotation}
end

return M
