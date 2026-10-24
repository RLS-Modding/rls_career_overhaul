-- Job skill levels, XP and reward multipliers.
-- All rewards retain their existing thresholds and rounding boundaries.
local M = {}
local skillLookup = require("overhaul/lib/progression/skillLookup")

local DEFAULT_MONEY_PERCENT_PER_LEVEL = 0.02

function M.loadRewardConfig(configPath)
  if type(configPath) ~= "string" or configPath == "" then
    return {}
  end
  return jsonReadFile(configPath) or {}
end

function M.getSkillConfig(rewardConfig)
  if type(rewardConfig) == "table" then
    return rewardConfig.skill or {}
  end
  return {}
end

function M.getAttributeKey(skillConfig, defaultKey)
  local configuredKey = skillConfig and skillConfig.attributeKey
  if type(configuredKey) == "string" and configuredKey ~= "" then
    return configuredKey
  end
  return defaultKey
end

-- attribute's XP; at least 1 (payout level) or 0 (raw); that minimum outside a career.
function M.getSkillLevel(attributeKey, pathIds)
  return skillLookup.levelMaxOverRefs(attributeKey, pathIds, 1)
end

function M.getSkillLevelRaw(attributeKey, pathIds)
  return skillLookup.levelMaxOverRefs(attributeKey, pathIds, 0)
end

function M.getMoneyBonusMultiplier(skillConfig, skillLevel)
  local laneIndex = math.floor(tonumber(skillConfig and skillConfig.rewardLaneIndex) or 0)
  local laneCount = math.floor(tonumber(skillConfig and skillConfig.rewardLaneCount) or 0)
  if laneIndex >= 1 and laneCount >= laneIndex then
    local level = math.max(1, math.min(50, math.floor(tonumber(skillLevel) or 1)))
    local bonus = 0
    for unlockedLevel = 2, math.min(49, level) do
      if ((unlockedLevel - 2) % laneCount) + 1 == laneIndex then bonus = bonus + (0.04 * laneCount) end
    end
    if level >= 50 then bonus = bonus + 0.08 end
    return 1 + math.min(2, bonus)
  end
  local configuredPerLevel = tonumber(skillConfig and skillConfig.moneyPercentPerLevel)
  local perLevelPercent = configuredPerLevel or DEFAULT_MONEY_PERCENT_PER_LEVEL
  local effectiveLevelUps = math.max(0, (tonumber(skillLevel) or 1) - 1)
  return 1 + (effectiveLevelUps * perLevelPercent)
end

-- Level 10 unlocks Quarry Work without a bonus, so its reward lane resumes at 11.
local operatorRewardLaneCycle = {2, 1, 2, 3, 1, 2, 3, 2, 1, 3}

function M.getOperatorRewardLaneForLevel(unlockedLevel)
  local level = math.floor(tonumber(unlockedLevel) or 0)
  if level < 2 or level >= 50 then return nil end
  if level < 10 then
    return level % 2 == 0 and 1 or 3
  end
  if level == 10 then return nil end
  return operatorRewardLaneCycle[((level - 10) % #operatorRewardLaneCycle) + 1]
end

function M.getOperatorMoneyBonusMultiplier(laneIndex, skillLevel)
  local requestedLane = math.floor(tonumber(laneIndex) or 0)
  if requestedLane < 1 or requestedLane > 3 then return 1 end
  local level = math.max(1, math.min(50, math.floor(tonumber(skillLevel) or 1)))
  local bonus = 0
  for unlockedLevel = 2, math.min(49, level) do
    if M.getOperatorRewardLaneForLevel(unlockedLevel) == requestedLane then
      bonus = bonus + 0.12
    end
  end
  if level >= 50 then
    -- Quarry skips the level-10 bonus, so mastery supplies the missing 12%
    bonus = bonus + (requestedLane == 2 and 0.20 or 0.08)
  end
  return 1 + math.min(2, bonus)
end

function M.getMoneyBonusPercent(skillConfig, skillLevel)
  return math.floor((M.getMoneyBonusMultiplier(skillConfig, skillLevel) - 1) * 100 + 0.5)
end

function M.getJobMoneyBonusMultiplier(childSkillConfig, childSkillLevel)
  return M.getMoneyBonusMultiplier(childSkillConfig, childSkillLevel)
end

function M.awardJobSkillXp(childAttributeKey, childSkillConfig, payAmount, reason)
  local xpAmount = M.getSkillRewardAmount(childSkillConfig, payAmount)
  if xpAmount <= 0 then
    return 0
  end
  M.awardSkillXp(childAttributeKey, xpAmount, reason)
  return xpAmount
end

local function paySkillReward(rewardData, reason)
  local xp = {}
  for key, entry in pairs(rewardData) do xp[key] = entry.amount end
  -- A scaler can remove every entry; awardSkillXp still posts that empty change, so
  -- the payout must accept an empty XP map.
  return overhaul_career_economy_payment.payout({xp = xp, reason = reason or {}, fullReward = true,
    allowEmpty = true})
end

function M.awardFlatJobSkillXp(childAttributeKey, xpAmount, reason)
  if not xpAmount or xpAmount <= 0 then
    return 0
  end
  if not overhaul_career_career.isActive() then
    return 0
  end
  local rewardData = {}
  M.addJobSkillXpToRewardData(rewardData, childAttributeKey, xpAmount)
  overhaul_career_economy_difficultyMode.scalePaymentRewardData(rewardData, { includeMoney = false })
  local awarded = (rewardData[childAttributeKey] and rewardData[childAttributeKey].amount) or 0
  if awarded > 0 then
    local accepted = paySkillReward(rewardData, reason)
    -- The legacy return measures scaled XP even when the payment is refused.
    if accepted ~= true then return awarded end
  end
  return awarded
end

function M.isPlayerOwnedInventoryVehicle(vehId)
  if not vehId or not overhaul_career_career.isActive() then
    return false
  end
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
  if not inventoryId then
    return false
  end
  local vehInfo = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  return vehInfo ~= nil and vehInfo.owned == true
end

function M.addJobSkillXpToRewardData(rewardData, childAttributeKey, xpAmount)
  if not rewardData or not xpAmount or xpAmount <= 0 then
    return 0
  end
  local childEntry = rewardData[childAttributeKey]
  local childTotal = (childEntry and tonumber(childEntry.amount)) or 0
  rewardData[childAttributeKey] = { amount = childTotal + xpAmount }
  return xpAmount
end

function M.getSkillRewardAmount(skillConfig, baseAmount)
  local xpConfig = (skillConfig and skillConfig.xpReward) or {}
  local mode = xpConfig.mode or "money"
  local multiplier = tonumber(xpConfig.multiplier) or 1.0
  local minimum = tonumber(xpConfig.minimum) or 1
  local baseValue = 0
  if mode == "money" then
    baseValue = tonumber(baseAmount) or 0
  elseif mode == "reputationScale" then
    local divisor = tonumber(xpConfig.divisor) or 1
    if divisor > 0 then
      baseValue = (tonumber(baseAmount) or 0) / divisor
    end
  end
  local rewardAmount = baseValue * multiplier
  local rounding = xpConfig.rounding or "floor"
  if rounding == "round" then
    rewardAmount = math.floor(rewardAmount + 0.5)
  else
    rewardAmount = math.floor(rewardAmount)
  end
  return math.max(minimum, rewardAmount)
end

function M.awardSkillXp(attributeKey, amount, reason)
  if not amount or amount <= 0 then
    return 0
  end
  if not overhaul_career_career.isActive() then
    return 0
  end
  local rewardData = {}
  rewardData[attributeKey] = { amount = amount }
  overhaul_career_economy_difficultyMode.scalePaymentRewardData(rewardData, { includeMoney = false })
  local awarded = (rewardData[attributeKey] and rewardData[attributeKey].amount) or amount
  if awarded > 0 then
    local accepted = paySkillReward(rewardData, reason)
    -- The legacy return measures scaled XP even when the payment is refused.
    if accepted ~= true then return awarded end
  end
  return awarded
end

return M
