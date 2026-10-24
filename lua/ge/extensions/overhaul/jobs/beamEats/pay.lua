-- BeamEats distance pay, smooth-driving tips and logistics progression.
-- The delivery owner supplies config; RNG draws stay in the tip calculation.
local configRules = require('overhaul/jobs/beamEats/config')

return function(config, logisticsXPConfig)
  local function getLogisticsLevel()
    return logisticsXPConfig.getLogisticsLevel()
  end

  local function getLogisticsMoneyBonusMultiplier()
    local level = getLogisticsLevel()
    local effectiveLevel = math.max(1, math.min(50, math.floor(tonumber(level) or 1)))
    local rawBonus = 0
    for unlockedLevel = 2, math.min(49, effectiveLevel) do
      if ((unlockedLevel - 2) % 2) + 1 == 2 then rawBonus = rawBonus + 0.08 end
    end
    if effectiveLevel >= 50 then rawBonus = rawBonus + 0.08 end
    return 1.0 + rawBonus, rawBonus
  end

  local function calculateRatingPayMultiplier(rating)
    local maxBonus = configRules.value(config, "maxRatingBonus")
    local normalized = math.min(1.0, math.max(0.0, (rating or 0) / 5.0))
    return 1.0 + (normalized * normalized) * maxBonus
  end

  local function getPromotionState()
    return "Courier", 0, 1.0
  end

  local function getBeamEatsXpRules()
    return logisticsXPConfig.getBeamEatsRules()
  end

  local function getStreakXpBonus(streak)
    local rules = getBeamEatsXpRules()
    local tiers = rules.streakTiers or {}
    for _, tier in ipairs(tiers) do
      if streak <= (tier.maxStreak or 0) then
        return tier.xp or 0
      end
    end
    return 0
  end

  local function calculateLogisticsXp(distanceMeters, streak)
    local rules = getBeamEatsXpRules()
    local baseXP = tonumber(rules.baseXP) or 24
    local distanceDivisor = tonumber(rules.distanceDivisor) or 400
    local xpRounding = rules.xpRounding or "round"
    local function roundFn(value)
      return logisticsXPConfig.applyRounding(value, xpRounding)
    end

    local distanceXp = 0
    if distanceMeters and distanceDivisor > 0 then
      distanceXp = roundFn(distanceMeters / distanceDivisor)
    end

    local _, _, xpMultiplier = getPromotionState()
    local rawXp = (baseXP + distanceXp + getStreakXpBonus(streak)) * xpMultiplier
    return math.max(0, roundFn(rawXp))
  end

  local function computeDistancePay(totalDistance)
    local distancePay = config.baseFarePerKm * (totalDistance / 1000)
    local economyMultiplier = 1.0

    if overhaul_career_economyAdjuster then
      economyMultiplier = overhaul_career_economyAdjuster.getSectionMultiplier("beamEats") or 1.0
      distancePay = distancePay * economyMultiplier
    end

    return distancePay, economyMultiplier
  end

  local function calculateSmoothDrivingTip(baseFare, roughEvents)
    local rand = math.random()

    if rand < config.zeroTipChance then
      return 0
    end

    if rand < (config.zeroTipChance + config.hugeTipChance) then
      return baseFare
    end

    -- Create a sorted local copy of tipTiers to avoid ordering issues
    local tiers = {}
    for _, t in ipairs(config.tipTiers) do table.insert(tiers, t) end
    table.sort(tiers, function(a, b) return a.maxEvents < b.maxEvents end)

    for _, tier in ipairs(tiers) do
      if roughEvents <= tier.maxEvents then
        return baseFare * tier.percent
      end
    end

    -- Fallback for > 20 events (very rough driving) Generous customers (50% chance) will still give a small tip (5%)
    if math.random() < 0.5 then
      return baseFare * 0.05
    end

    return 0
  end

  return {calculateLogisticsXp = calculateLogisticsXp,
    calculateRatingPayMultiplier = calculateRatingPayMultiplier,
    calculateSmoothDrivingTip = calculateSmoothDrivingTip, computeDistancePay = computeDistancePay,
    getLogisticsLevel = getLogisticsLevel,
    getLogisticsMoneyBonusMultiplier = getLogisticsMoneyBonusMultiplier,
    getPromotionState = getPromotionState}
end
