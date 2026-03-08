-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local floor = math.floor
local max = math.max

M.dependencies = {'career_career', 'gameplay_walk'}

local METERS_PER_XP = 2
local MIN_XP_GRANT = 5
local MAX_DISTANCE_STEP = 20
local SPEED_BONUS_PER_LEVEL = 0.02
local MIN_SPEED_MULTIPLIER = 1
local MAX_SPEED_MULTIPLIER = 2

local state = {
  pendingMeters = 0,
  lastPos = nil,
  lastAppliedVehId = nil,
  lastAppliedMultiplier = nil
}

local function resetWalkTracking()
  state.lastPos = nil
end

local function getStaminaLevel()
  if not career_branches or not career_branches.getBranchLevel then
    return 1
  end

  local level = tonumber(career_branches.getBranchLevel('stamina')) or 1
  return max(level, 1)
end

local function getSpeedMultiplierForLevel(level)
  local bonusLevels = max(0, level - 1)
  local multiplier = 1 + bonusLevels * SPEED_BONUS_PER_LEVEL
  return clamp(multiplier, MIN_SPEED_MULTIPLIER, MAX_SPEED_MULTIPLIER)
end

local function applySpeedMultiplier(multiplier)
  local playerVeh = getPlayerVehicle(0)
  if not playerVeh or playerVeh:getJBeamFilename() ~= 'unicycle' then
    state.lastAppliedVehId = nil
    return
  end

  local vehId = playerVeh:getID()
  if state.lastAppliedVehId == vehId and state.lastAppliedMultiplier == multiplier then
    return
  end

  playerVeh:queueLuaCommand(string.format("controller.getControllerSafe('playerController').setMovementSpeedMultiplier(%0.4f)", multiplier))
  state.lastAppliedVehId = vehId
  state.lastAppliedMultiplier = multiplier
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

  state.pendingMeters = max(0, state.pendingMeters - xp * METERS_PER_XP)

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
  applySpeedMultiplier(speedMultiplier)

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
end

M.onUpdate = onUpdate
M.onClientStartMission = onClientStartMission

return M
