-- Stamina training: walking while the career is active earns stamina XP per meter.
-- The stamina level also scales the walk speed and jump of the player's controller; the scaled values are sent only when they change.
local M = {}

local floor = math.floor
local max = math.max
local skillLookup = require("overhaul/lib/progression/skillLookup")

local METERS_PER_XP = 1
local MIN_XP_GRANT = 5 -- smaller grants wait until they add up
local SPEED_MARGIN = 1.25 -- allow slopes and controller/GE frame timing
local MAX_RELATIVE_STEP_METERS = 10 -- reject large jumps after removing support motion
local MAX_REPORT_AGE = 0.25 -- fail closed if the avatar controller stops reporting
local UNCONTROLLED_FLUSH_SECONDS = 0.5
local PATCH_ID = "staminaWalkBaseline"
local SPEED_BONUS_PER_LEVEL = 0.02
local MIN_SPEED_MULTIPLIER = 1
local MAX_SPEED_MULTIPLIER = 2
local JUMP_BONUS_PER_LEVEL = 0.02
local MIN_JUMP_MULTIPLIER = 1
local MAX_JUMP_MULTIPLIER = 2
local STAMINA_REFS = {"stamina", "careerSkills-stamina"}
local MULTIPLIER_COMMAND = "local c=controller.getControllerSafe('overhaulPlayerController');if c then if c.updateSpeed then c.updateSpeed(%0.4f) elseif c.setMovementSpeedMultiplier then c.setMovementSpeedMultiplier(%0.4f) end if c.updateJumpForce then c.updateJumpForce(%0.4f) elseif c.setJumpForceMultiplier then c.setJumpForceMultiplier(%0.4f) end end"

local state = {
  pendingMeters = 0,
  lastForcedMeters = nil,
  lastPos = nil,
  lastAppliedVehId = nil,
  lastAppliedMultiplier = nil,
  lastAppliedJumpMultiplier = nil,
  moveVehId = nil,
  moveAge = math.huge,
  controlled = false,
  uncontrolledTime = 0,
  maxWalkSpeed = 0,
  supportX = 0, supportY = 0, supportZ = 0,
}

local lastPosScratch = vec3()

-- Some branch APIs return several values; only the first one is the number.
local function tonumberFirst(...)
  local value = select(1, ...)
  return tonumber(value)
end

local function resetWalkTracking()
  state.lastPos = nil
end

-- The avatar reports actual player input and contact motion, not just walking mode.
local function noteWalkingMotion(vehId, controlled, maxSpeed, supportX, supportY, supportZ)
  local player = getPlayerVehicle(0)
  if not player or player:getID() ~= vehId then return end
  state.moveVehId = vehId
  state.moveAge = 0
  state.controlled = controlled == true
  state.maxWalkSpeed = tonumber(maxSpeed) or 0
  state.supportX, state.supportY, state.supportZ = supportX or 0, supportY or 0, supportZ or 0
  if not state.controlled then resetWalkTracking() end
end

local function resetPlayerTracking(vehId)
  local player = getPlayerVehicle(0)
  if vehId == nil or (player and player:getID() == vehId) then resetWalkTracking() end
end

local function getStaminaLevel()
  local level = skillLookup.maxPathLevel(0, STAMINA_REFS)

  if skillLookup.hasValueLevels() then
    local staminaValue = tonumberFirst(skillLookup.attributeValue("stamina"))
    local altValue = tonumberFirst(skillLookup.attributeValue("careerSkills-stamina"))

    if altValue and (not staminaValue or altValue > staminaValue) then
      staminaValue = altValue
    end

    if staminaValue then
      level = skillLookup.maxValueLevel(level, staminaValue, STAMINA_REFS)
    end
  end

  return max(level, 1)
end

local function getSpeedMultiplierForLevel(level)
  local bonusLevels = max(0, level - 1)
  local multiplier = 1 + bonusLevels * SPEED_BONUS_PER_LEVEL
  return clamp(multiplier, MIN_SPEED_MULTIPLIER, MAX_SPEED_MULTIPLIER)
end

local function getJumpMultiplierForLevel(level)
  local bonusLevels = max(0, level - 1)
  local multiplier = 1 + bonusLevels * JUMP_BONUS_PER_LEVEL
  return clamp(multiplier, MIN_JUMP_MULTIPLIER, MAX_JUMP_MULTIPLIER)
end

-- Sends the multipliers to the player's controller, skipping the send when nothing changed.
local function applyMovementMultipliers(speedMultiplier, jumpMultiplier)
  local playerVeh = getPlayerVehicle(0)
  if not playerVeh then
    state.lastAppliedVehId = nil
    state.controlled = false
    state.moveAge = math.huge
    return
  end

  local vehId = playerVeh:getID()
  if state.lastAppliedVehId == vehId and state.lastAppliedMultiplier == speedMultiplier and state.lastAppliedJumpMultiplier == jumpMultiplier then
    return
  end

  playerVeh:queueLuaCommand(string.format(MULTIPLIER_COMMAND, speedMultiplier, speedMultiplier, jumpMultiplier, jumpMultiplier))
  state.lastAppliedVehId = vehId
  state.lastAppliedMultiplier = speedMultiplier
  state.lastAppliedJumpMultiplier = jumpMultiplier
end

-- A vehicle ID survives controller replacement. Only the ready notification proves
-- the new controller can receive settings; reset/spawn hooks can run too early.
local function onPlayerControllerReady(vehId)
  local player = getPlayerVehicle(0)
  if not overhaul_career_career.isActive() or not player or player:getID() ~= vehId then return end
  state.lastAppliedVehId = nil
  local level = getStaminaLevel()
  applyMovementMultipliers(getSpeedMultiplierForLevel(level), getJumpMultiplierForLevel(level))
end

-- Grants whole XP from the pending meters. The difficulty mode scales the grant before it is applied.
local function grantPendingXP(force)
  if state.pendingMeters <= 0 then
    return
  end

  local xp = floor(state.pendingMeters / METERS_PER_XP)
  if xp <= 0 then
    return
  end

  if not force and xp < MIN_XP_GRANT then
    return
  end

  -- A scaled remainder can round to zero; retry only after more distance.
  if force then
    if state.lastForcedMeters == state.pendingMeters then return end
    state.lastForcedMeters = state.pendingMeters
  end

  local rawXp = xp

  local scaled = { stamina = rawXp }
  overhaul_career_economy_difficultyMode.scaleFlatRewards(scaled, {includeMoney = false})
  xp = floor(tonumber(scaled.stamina) or rawXp)

  if xp <= 0 then
    return
  end

  state.pendingMeters = max(0, state.pendingMeters - rawXp * METERS_PER_XP)
  state.lastForcedMeters = nil

  overhaul_career_economy_playerAttributes.addAttributes({
    stamina = xp
  }, {
    label = string.format("Stamina Training (+%d XP)", xp),
    tags = {"gameplay", "stamina"}
  }, true)
end

-- Only controlled, grounded steps within the controller's speed limit are training.
local function onUpdate(dtReal, dtSim, dtRaw)
  if not overhaul_career_career.isActive() or not overhaul_career_economy_playerAttributes then
    resetWalkTracking()
    state.controlled = false
    return
  end

  local walking = gameplay_walk.isWalking()
  if not walking then
    grantPendingXP(true)
    resetWalkTracking()
    state.lastAppliedVehId = nil
    state.controlled = false
    state.moveAge = math.huge
    state.uncontrolledTime = 0
    return
  end

  local level = getStaminaLevel()
  applyMovementMultipliers(getSpeedMultiplierForLevel(level), getJumpMultiplierForLevel(level))

  local playerVeh = getPlayerVehicle(0)
  if not playerVeh then
    resetWalkTracking()
    return
  end

  state.moveAge = state.moveAge + max(0, dtSim)
  if dtSim <= 0 or state.moveAge > MAX_REPORT_AGE or not state.controlled
      or state.moveVehId ~= playerVeh:getID() or state.maxWalkSpeed <= 0 then
    state.uncontrolledTime = state.uncontrolledTime + max(0, dtSim)
    if state.uncontrolledTime >= UNCONTROLLED_FLUSH_SECONDS then grantPendingXP(true) end
    resetWalkTracking()
    return
  end

  state.uncontrolledTime = 0
  local currentPos = playerVeh:getPosition()
  if state.lastPos then
    -- Contact motion supplied by a support is never training, even on fast lifts.
    local dx = currentPos.x - state.lastPos.x - state.supportX * dtSim
    local dy = currentPos.y - state.lastPos.y - state.supportY * dtSim
    local dz = currentPos.z - state.lastPos.z - state.supportZ * dtSim
    local relativeMeters = math.sqrt(dx*dx + dy*dy + dz*dz)
    if relativeMeters <= MAX_RELATIVE_STEP_METERS then
      if relativeMeters > 0 and relativeMeters <= state.maxWalkSpeed * SPEED_MARGIN * dtSim then
        state.pendingMeters = state.pendingMeters + relativeMeters
      end
    end
  end

  lastPosScratch:set(currentPos)
  state.lastPos = lastPosScratch
  grantPendingXP(false)
end

local function onClientStartMission()
  state.pendingMeters = 0
  state.lastForcedMeters = nil
  state.lastPos = nil
  state.lastAppliedVehId = nil
  state.lastAppliedMultiplier = nil
  state.lastAppliedJumpMultiplier = nil
  state.controlled = false
  state.uncontrolledTime = 0
  state.moveVehId = nil
  state.moveAge = math.huge
  state.maxWalkSpeed = 0
  state.supportX, state.supportY, state.supportZ = 0, 0, 0
end

local function onExtensionLoaded()
  -- safeTeleport covers quick/map travel, garages, recovery, buildings and console calls,
  -- even with resetVehicle=false. The patch registry restores stock functions on unload.
  overhaul_shell_patches.registerFields(PATCH_ID, function() return rawget(_G, 'spawn') end, {
    safeTeleport = function(original)
      return function(veh, ...)
        if veh then resetPlayerTracking(veh:getID()) end
        return original(veh, ...)
      end
    end,
  })
end

local function onExtensionUnloaded()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

M.onUpdate = onUpdate
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientStartMission
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.noteWalkingMotion = noteWalkingMotion
M.onPlayerControllerReady = onPlayerControllerReady
M.onOverhaulPlayerPositionReset = resetPlayerTracking
M.onVehicleResetted = resetPlayerTracking
M.onVehicleSwitched = resetWalkTracking
M.onBeforeWalkingModeToggled = resetWalkTracking
M.onTeleportedToGarage = resetWalkTracking
M.teleportedFromBigmap = resetWalkTracking
M.onRecoveryPromptButtonPressed = resetWalkTracking
M.onOverhaulActive = onClientStartMission

return M
