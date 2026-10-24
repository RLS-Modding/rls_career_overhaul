-- Player-controller additions: stamina multipliers, external walking input and movement reports to GE.
-- Each controller instance owns its base physics values and input state; the stock controller keeps its layout.
local geCallback = require('vehicle/overhaul/geCallback')

local abs = math.abs

local M = {}

function M.create()
  local seam = {}

  local speedMultiplier = 1
  local jumpForceMultiplier = 1

  local baseStabilizationMaxForce
  local baseYawMaxForce
  local baseWalkingSpeed
  local baseSprintSpeed
  local baseMaxBallTorque
  local baseJumpForce
  local speedMultiplierSet = false
  local jumpMultiplierSet = false

  local externalMove = nil
  local externalMoveVector = vec3(0, 0, 0)
  local notedMoveSpeedCoef, notedMoveWalkLen = nil, nil
  local lastWalkingControlled

  -- init: the jbeam values the multipliers scale.
  function seam.captureBase(walkingSpeed, sprintSpeed, maxBallTorque, stabilizationMaxForce, yawMaxForce, jumpForce)
    baseWalkingSpeed = walkingSpeed
    baseSprintSpeed = sprintSpeed
    baseMaxBallTorque = maxBallTorque
    baseStabilizationMaxForce = stabilizationMaxForce
    baseYawMaxForce = yawMaxForce
    baseJumpForce = jumpForce
  end

  function seam.speedMultiplierSet() return speedMultiplierSet end
  function seam.jumpMultiplierSet() return jumpMultiplierSet end
  function seam.hasSpeedBase() return not not baseWalkingSpeed end
  function seam.speedMultiplier() return speedMultiplier end

  -- Separate calculations keep the fork's partial assignments when a later base value is malformed.
  function seam.scaledWalkingSpeed(speedMult)
    return baseWalkingSpeed * speedMult
  end

  function seam.scaledSprintSpeed(speedMult)
    return baseSprintSpeed * speedMult
  end

  function seam.scaledBallTorque(speedMult)
    return baseMaxBallTorque * speedMult
  end

  function seam.scaledStabilizationForce(speedMult)
    return baseStabilizationMaxForce * (speedMult * 0.25)
  end

  function seam.scaledYawForce(speedMult)
    return baseYawMaxForce * (speedMult * 0.25)
  end

  function seam.scaledJumpForce()
    if not baseJumpForce then return nil end
    return baseJumpForce * jumpForceMultiplier
  end

  function seam.setSpeedMultiplier(speedMult)
    speedMult = tonumber(speedMult) or 1

    speedMultiplier = speedMult
    speedMultiplierSet = true
  end

  function seam.setJumpForceMultiplier(jumpForceMult)
    jumpForceMult = tonumber(jumpForceMult) or 1

    jumpForceMultiplier = jumpForceMult
    jumpMultiplierSet = true
  end

  function seam.setExternalMove(x, y, speedCoef)
    if x == nil then
      externalMove = nil
    else
      externalMove = {x = x or 0, y = y or 0, speedCoef = speedCoef}
    end
  end

  function seam.setExternalWorldMove(x, y, speedCoef)
    if x == nil then
      externalMove = nil
    else
      externalMove = {x = x or 0, y = y or 0, speedCoef = speedCoef, worldSpace = true}
    end
  end

  function seam.clearExternalMove()
    externalMove = nil
  end

  -- The external move replaces the walk input, and its speed coefficient when given, in updateFixedStep.
  function seam.propulsionInput(movementSpeedCoef, walkVector)
    local speedCoef = movementSpeedCoef
    local moveInput = walkVector
    local worldSpaceMove = false
    if externalMove then
      externalMoveVector:set(externalMove.x or 0, externalMove.y or 0, 0)
      moveInput = externalMoveVector
      worldSpaceMove = externalMove.worldSpace == true
      if externalMove.speedCoef ~= nil then
        speedCoef = externalMove.speedCoef
      end
    end
    return speedCoef, moveInput, worldSpaceMove
  end

  -- updateGFX: tell GE (stamina) when the seated player's movement input changes.
  function seam.noteMove(firstPlayerSeated, movementSpeedCoef, walkVector)
    if firstPlayerSeated then
      local walkLen = walkVector:length()
      if notedMoveSpeedCoef == nil or abs(movementSpeedCoef - notedMoveSpeedCoef) > 1e-3 or
          abs(walkLen - notedMoveWalkLen) > 1e-3 then
        notedMoveSpeedCoef, notedMoveWalkLen = movementSpeedCoef, walkLen
        obj:queueGameEngineLua(geCallback.command("notePlayerMove", string.format("%s,%s", movementSpeedCoef, walkLen)))
      end
    else
      notedMoveSpeedCoef = nil
    end
  end

  -- A heartbeat prevents stale input being reused after a reset or controller loss.
  function seam.noteWalkingMotion(seated, walkVector, frozen, grounded, worldVelocity, relativeVelocity, maxSpeed)
    local dx, dy, dz = worldVelocity.x-relativeVelocity.x, worldVelocity.y-relativeVelocity.y, worldVelocity.z-relativeVelocity.z
    local controlled = seated and not frozen and not externalMove and grounded
      and walkVector:length() > 1e-3 and relativeVelocity:length() > 1e-3
    local valid = maxSpeed == maxSpeed and abs(maxSpeed) < math.huge
      and dx == dx and abs(dx) < math.huge and dy == dy and abs(dy) < math.huge and dz == dz and abs(dz) < math.huge
    if not valid then controlled, maxSpeed, dx, dy, dz = false, 0, 0, 0, 0 end
    controlled = not not controlled
    if not controlled and lastWalkingControlled == false then return end
    lastWalkingControlled = controlled
    obj:queueGameEngineLua(geCallback.command("staminaWalkingMotion",
      string.format("%d,%s,%.4f,%.9f,%.9f,%.9f", obj:getId(), tostring(not not controlled), maxSpeed, dx, dy, dz)))
  end

  return seam
end

return M
