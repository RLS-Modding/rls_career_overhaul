-- Stateless scoring shared by event rewards and leaderboard comparisons.
-- Economy policy is supplied by the caller so record comparisons stay unscaled.
local M = {}

local function raceReward(goal, reward, time, raceTypes, multiplierFor)
  local goalTime = goal
  local baseRewardValue = reward
  local elapsedTime = time
  if elapsedTime == 0 then return 0 end

  local baseReward
  local ratio = goalTime / elapsedTime
  if ratio < 1 then
    baseReward = math.floor(ratio * baseRewardValue * 100) / 100
  else
    baseReward = math.floor((math.pow(ratio, (1 + (baseRewardValue / 500)))) * baseRewardValue * 100) / 100
    if baseReward > baseRewardValue * 30 then baseReward = baseRewardValue * 30 end
  end

  if multiplierFor then
    local multiplier = multiplierFor(raceTypes)
    baseReward = baseReward * multiplier
    baseReward = math.floor(baseReward + 0.5) -- Round to nearest integer
  end

  return baseReward
end

local function hybridRaceReward(
  goalTime,
  baseReward,
  actualTime,
  damageFactor,
  damagePercentage,
  raceTypes,
  multiplierFor
)
  if damageFactor == 0 then return raceReward(goalTime, baseReward, actualTime, raceTypes, multiplierFor) end

  if damageFactor == 1 then
    local damageReward = baseReward * (1 - damagePercentage)
    if multiplierFor then
      local multiplier = multiplierFor(raceTypes)
      damageReward = damageReward * multiplier
      damageReward = math.floor(damageReward + 0.5)
    end
    return math.max(0, damageReward)
  end

  local timeReward = raceReward(goalTime, baseReward, actualTime)

  local finalReward = (baseReward * (1 - damagePercentage)) + (damageFactor * timeReward)
  if multiplierFor then finalReward = math.floor(finalReward * multiplierFor(raceTypes) + 0.5) end

  return math.max(0, finalReward)
end

local function driftReward(race, time, driftScore, multiplierFor)
  local goalTime = race.bestTime
  local goalDrift = race.driftGoal
  local timeFactor = (goalTime / time) ^ 1.2
  local driftFactor = (driftScore / goalDrift) ^ 1.2
  local reward = race.reward * timeFactor * driftFactor
  if multiplierFor then
    local multiplier = multiplierFor(race.type)
    reward = reward * multiplier
  end
  return reward
end

local function topSpeedReward(goalSpeed, baseReward, actualSpeed, raceTypes, multiplierFor)
  if actualSpeed == 0 then return 0 end

  local baseRewardValue
  local ratio = actualSpeed / goalSpeed
  if ratio < 1 then
    baseRewardValue = math.floor(ratio * baseReward * 100) / 100
  else
    baseRewardValue = math.floor((math.pow(ratio, (1 + (baseReward / 500)))) * baseReward * 100) / 100
    if baseRewardValue > baseReward * 30 then baseRewardValue = baseReward * 30 end
  end

  if multiplierFor then
    local multiplier = multiplierFor(raceTypes)
    baseRewardValue = baseRewardValue * multiplier
    baseRewardValue = math.floor(baseRewardValue + 0.5)
  end

  return baseRewardValue
end

M.driftReward = driftReward
M.topSpeedReward = topSpeedReward
M.raceReward = raceReward
M.hybridRaceReward = hybridRaceReward
return M
