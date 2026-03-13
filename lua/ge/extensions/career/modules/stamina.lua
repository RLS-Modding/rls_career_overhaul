-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local floor = math.floor
local max = math.max

M.dependencies = {'career_career', 'gameplay_walk'}

local METERS_PER_XP = 1
local MIN_XP_GRANT = 5
local MAX_DISTANCE_STEP = 20
local SPEED_BONUS_PER_LEVEL = 0.02
local MIN_SPEED_MULTIPLIER = 1
local MAX_SPEED_MULTIPLIER = 2
local JUMP_BONUS_PER_LEVEL = 0.02
local MIN_JUMP_MULTIPLIER = 1
local MAX_JUMP_MULTIPLIER = 2

local state = {
  pendingMeters = 0,
  lastPos = nil,
  lastAppliedVehId = nil,
  lastAppliedMultiplier = nil,
  lastAppliedJumpMultiplier = nil
}

-- Some branch APIs can return multiple values. Only the first one should be converted.
local function tonumberFirst(...)
  local value = select(1, ...)
  return tonumber(value)
end

local function resetWalkTracking()
  state.lastPos = nil
end

local function getStaminaLevel()
  local level = 0

  if career_branches and career_branches.getBranchLevel then
    level = max(level, tonumberFirst(career_branches.getBranchLevel('stamina')) or 0)
    level = max(level, tonumberFirst(career_branches.getBranchLevel('careerSkills-stamina')) or 0)
  end

  if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue and career_branches and career_branches.calcBranchLevelFromValue then
    local staminaValue = tonumberFirst(career_modules_playerAttributes.getAttributeValue('stamina'))
    local altValue = tonumberFirst(career_modules_playerAttributes.getAttributeValue('careerSkills-stamina'))

    if altValue and (not staminaValue or altValue > staminaValue) then
      staminaValue = altValue
    end

    if staminaValue then
      level = max(level, tonumberFirst(career_branches.calcBranchLevelFromValue(staminaValue, 'stamina')) or 0)
      level = max(level, tonumberFirst(career_branches.calcBranchLevelFromValue(staminaValue, 'careerSkills-stamina')) or 0)
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

local function applyMovementMultipliers(speedMultiplier, jumpMultiplier)
  local playerVeh = getPlayerVehicle(0)
  if not playerVeh then
    state.lastAppliedVehId = nil
    return
  end

  local vehId = playerVeh:getID()
  if state.lastAppliedVehId == vehId and state.lastAppliedMultiplier == speedMultiplier and state.lastAppliedJumpMultiplier == jumpMultiplier then
    return
  end

  playerVeh:queueLuaCommand(string.format("local c=controller.getControllerSafe('playerController');if c then if c.updateSpeed then c.updateSpeed(%0.4f) elseif c.setMovementSpeedMultiplier then c.setMovementSpeedMultiplier(%0.4f) end if c.updateJumpForce then c.updateJumpForce(%0.4f) elseif c.setJumpForceMultiplier then c.setJumpForceMultiplier(%0.4f) end end", speedMultiplier, speedMultiplier, jumpMultiplier, jumpMultiplier))
  state.lastAppliedVehId = vehId
  state.lastAppliedMultiplier = speedMultiplier
  state.lastAppliedJumpMultiplier = jumpMultiplier
end

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

  local rawXp = xp

  if career_modules_difficultyMode and career_modules_difficultyMode.scaleFlatRewards then
    local scaled = { stamina = rawXp }
    career_modules_difficultyMode.scaleFlatRewards(scaled, {includeMoney = false})
    xp = floor(tonumber(scaled.stamina) or rawXp)
  end

  if xp <= 0 then
    return
  end

  state.pendingMeters = max(0, state.pendingMeters - rawXp * METERS_PER_XP)

  career_modules_playerAttributes.addAttributes({
    stamina = xp
  }, {
    label = string.format('Stamina Training (+%d XP)', xp),
    tags = {'gameplay', 'stamina'}
  }, true)
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not career_career.isActive() or not career_modules_playerAttributes then
    return
  end

  local walking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()
  if not walking then
    grantPendingXP(true)
    resetWalkTracking()
    state.lastAppliedVehId = nil
    return
  end

  local level = getStaminaLevel()
  local speedMultiplier = getSpeedMultiplierForLevel(level)
  local jumpMultiplier = getJumpMultiplierForLevel(level)
  applyMovementMultipliers(speedMultiplier, jumpMultiplier)

  local playerVeh = getPlayerVehicle(0)
  if not playerVeh then
    return
  end

  local currentPos = playerVeh:getPosition()
  if state.lastPos then
    local stepMeters = (currentPos - state.lastPos):length()
    if stepMeters > 0 and stepMeters <= MAX_DISTANCE_STEP then
      state.pendingMeters = state.pendingMeters + stepMeters
    end
  end

  state.lastPos = vec3(currentPos)
  grantPendingXP(false)
end

local function onClientStartMission()
  state.pendingMeters = 0
  state.lastPos = nil
  state.lastAppliedVehId = nil
  state.lastAppliedMultiplier = nil
  state.lastAppliedJumpMultiplier = nil
end

M.onUpdate = onUpdate
M.onClientStartMission = onClientStartMission

return M
