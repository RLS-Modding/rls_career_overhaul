-- Shared delivery rewards, route factors and skill projections retain the existing optional career inputs.
-- Read multipliers, parcel rewards, vehicle offers and material rewards, then hardcore and economy adjustments.
local M = {}

local xpConfig = require("overhaul/lib/logistics/xpConfig")
local balance = require("overhaul/lib/logistics/logisticsBalance")

-- Config ------------------------------------------------------------------------------------------

local parcelHandlingRewardPerSlot = 1.15
local parcelDistanceRewardMultiplier = 1.075

-- A dry van carries 32 128-slot freight boxes. These payload bounds are cargo mass only and correspond to 30,000-40,000 lb across all 4,096 slots.
local PARCEL_FREIGHT_SLOT_CAPACITY = 32 * 128
local PARCEL_FREIGHT_MIN_PAYLOAD_KG = 30000 * 0.45359237
local PARCEL_FREIGHT_MAX_PAYLOAD_KG = 40000 * 0.45359237
local PARCEL_FREIGHT_MIN_KG_PER_SLOT = PARCEL_FREIGHT_MIN_PAYLOAD_KG / PARCEL_FREIGHT_SLOT_CAPACITY
local PARCEL_FREIGHT_MAX_KG_PER_SLOT = PARCEL_FREIGHT_MAX_PAYLOAD_KG / PARCEL_FREIGHT_SLOT_CAPACITY

local TRAILER_XP_GROUP_BY_TAG = {
  emptySmallTrailers = "small",
  loadedSmallTrailers = "small",
  trailerBoxutility = "small",
  trailerBoxutilityLarge = "small",
  trailerTsfb = "small",
  trailerCaravan = "small",
  emptyMediumTrailers = "medium",
  loadedMediumTrailers = "medium",
  trailerCargotrailer = "medium",
  trailerTiltdeck = "medium",
  trailerHeavyHitch = "heavyHitch",
  trailerDolly = "dryvan",
  trailerDryvan = "dryvan",
  emptyLargeTrailer = "flatbed",
  loadedLargeTrailers = "flatbed",
  trailerFlatbed = "flatbed",
  trailerFramelessDump = "dump",
  trailerTanker = "tanker",
  trailerContainer = "container",
  trailerLogTrailer = "log",
}

local TRAILER_XP_LEVEL_BY_GROUP = {
  small = 1,
  medium = 4,
  heavyHitch = 6,
  dryvan = 10,
  flatbed = 13,
  dump = 16,
  tanker = 19,
  container = 22,
  log = 25,
}

local VEHICLE_XP_TAGS = {
  junkerVeh = true,
  smallVeh = true,
  fleetVeh = true,
  highEndVeh = true,
  exoticVeh = true,
  heavyVeh = true,
  largeVeh = true,
}

-- State -------------------------------------------------------------------------------------------

-- Legacy multiplier and per-item money multiplier are set by callers at runtime and default to neutral.
local legacyHardcoreMultiplier = 1
local parcelItemMoneyMultiplier = 1

-- Helpers -----------------------------------------------------------------------------------------

local function getProgressionMultiplier()
  return overhaul_career_economy_difficultyMode.getXPMultiplierForKey("logistics-delivery")
end

local function applyMoneyRounding(value)
  return xpConfig.applyRounding(value, xpConfig.getConfig().rounding.moneyFinal)
end

local function getVehicleBaseXP(rules, filter)
  if type(rules.vehicleXPByTag) ~= "table" or not filter or not filter.unlockTag then
    return rules.baseXP
  end

  local tag = filter.unlockTag
  if not VEHICLE_XP_TAGS[tag] then
    return rules.baseXP
  end

  local tagXP = rules.vehicleXPByTag[tag]
  if type(tagXP) == "number" then
    return tagXP
  end

  return rules.baseXP
end

local function getTrailerBaseXP(rules, filter)
  if not filter or not filter.unlockTag then
    return rules.baseXP
  end

  local unlockGroup = TRAILER_XP_GROUP_BY_TAG[filter.unlockTag]
  if not unlockGroup then
    return rules.baseXP
  end

  if type(rules.trailerXPByUnlockGroup) == "table" then
    local groupXP = rules.trailerXPByUnlockGroup[unlockGroup]
    if type(groupXP) == "number" then
      return groupXP
    end
  end

  if type(rules.trailerXPByUnlockLevel) == "table" then
    local unlockLevel = TRAILER_XP_LEVEL_BY_GROUP[unlockGroup]
    local levelXP = rules.trailerXPByUnlockLevel[tostring(unlockLevel)]
    if type(levelXP) == "number" then
      return levelXP
    end
  end

  return rules.baseXP
end

local function getTrailerMoneyMultiplier(rules, filter)
  if not filter or not filter.unlockTag then
    return 1
  end

  local unlockGroup = TRAILER_XP_GROUP_BY_TAG[filter.unlockTag]
  local multipliers = rules.trailerMoneyMultiplierByUnlockGroup
  if not unlockGroup or type(multipliers) ~= "table" then
    return 1
  end

  local multiplier = multipliers[unlockGroup]
  return type(multiplier) == "number" and multiplier or 1
end

local function getMaterialBaseXP(rules, materialType)
  if type(rules.baseXPByType) ~= "table" or type(materialType) ~= "string" then
    return rules.baseXP
  end

  local overrideXP = rules.baseXPByType[materialType]
  if type(overrideXP) == "number" then
    return overrideXP
  end

  return rules.baseXP
end

local function getParcelBaseXP(slots)
  local rules = xpConfig.getParcelRules()

  if type(rules.slotXPBySize) == "table" and #rules.slotXPBySize > 0 then
    local tierXP = rules.baseXP
    for _, tier in ipairs(rules.slotXPBySize) do
      if slots >= tier.slots then
        tierXP = tier.xp
      else
        break
      end
    end
    return tierXP, rules
  end

  local baseXP = rules.baseXP
  for _, threshold in ipairs(rules.slotMilestones) do
    if slots >= threshold then
      baseXP = baseXP + 1
    end
  end
  return baseXP, rules
end

local function getParcelDistanceXP(distance, baseXP, rules)
  local distanceTerm = xpConfig.applyRounding(distance / rules.distanceDivisor, rules.distanceRounding)
  return balance.roundXP((baseXP + distanceTerm) * getProgressionMultiplier())
end

local function getParcelRewardWeight(item)
  -- This is an economic calibration value inherited from the old templates. Never fall back to physical item.weight: vehicle mass must not affect pay.
  return math.max(0, tonumber(item.data and item.data.rewardWeight) or 0)
end

local function orgDeliveryBonus(organizationData)
  local levels = organizationData and organizationData.reputationLevels
  local level = organizationData and organizationData.reputation and tonumber(organizationData.reputation.level)
  local levelData = levels and level and levels[level + 2]
  local bonus = levelData and levelData.deliveryBonus
  return bonus and tonumber(bonus.value) or nil
end

local function getParcelWeightRate(rewardWeight)
  if rewardWeight <= 10 then
    return math.pow(rewardWeight, 0.9)
  end
  return math.pow(10, 0.9) + 4.7 * math.log(1 + (rewardWeight - 10) / 10)
end

-- Public API: multipliers -------------------------------------------------------------------------

function M.setHardcoreMultiplier(value)
  legacyHardcoreMultiplier = value or 1
end

function M.getHardcoreMultiplier()
  return legacyHardcoreMultiplier
end

function M.setParcelItemMoneyMultiplier(value)
  parcelItemMoneyMultiplier = value or 1
end

-- Public API: parcel rewards ----------------------------------------------------------------------

-- Returns physical kilograms for a generated parcel. Lightweight cargo keeps its authored mass; freight scales by slots so 32 128-slot boxes total 30,000-40,000 lb. The seed makes save migration stable and repeatable.
function M.getPhysicalWeightForParcel(template, slots, authoredWeight, seed)
  local slotCount = math.max(0, tonumber(slots) or 0)
  local physicalWeightClass = template and template.physicalWeightClass
  if not physicalWeightClass then
    local isPost = template and template.modChance and (tonumber(template.modChance.post) or 0) > 0
    -- Expansion maps predate physicalWeightClass. Treat their 128-slot boxes as freight by default, but never turn authored postal cargo into freight.
    physicalWeightClass = slotCount >= 128 and not isPost and "freight" or "light"
  end
  if physicalWeightClass ~= "freight" then
    return math.max(0, tonumber(authoredWeight) or 0)
  end

  local stableSeed = math.abs(math.floor(tonumber(seed) or 0))
  local densityFraction = (stableSeed % 10000) / 9999
  local kgPerSlot = PARCEL_FREIGHT_MIN_KG_PER_SLOT
    + (PARCEL_FREIGHT_MAX_KG_PER_SLOT - PARCEL_FREIGHT_MIN_KG_PER_SLOT) * densityFraction
  return slotCount * kgPerSlot
end

function M.getMoneyRewardForParcelItem(item, distance)
  local slots = math.max(1, tonumber(item.slots) or 1)
  local distanceKm = math.max(0, tonumber(distance) or 0) / 1000
  local rewardWeight = getParcelRewardWeight(item)
  local slotRate = math.pow(3, 0.30 + math.sqrt(slots) / 100)
  local minimumReward = 10 + 2 * math.sqrt(slots)
  local handlingReward = slots * parcelHandlingRewardPerSlot
  local rewardPerKm = slotRate * (5 + getParcelWeightRate(rewardWeight)) * parcelDistanceRewardMultiplier
  local baseReward = math.max(minimumReward, handlingReward + distanceKm * rewardPerKm)
  local target, referenceWeight = balance.getParcelPay(slots)
  local referenceRate = slotRate * (5 + getParcelWeightRate(referenceWeight)) * parcelDistanceRewardMultiplier
  local referenceReward = math.max(minimumReward,
    handlingReward + balance.referenceDistance / 1000 * referenceRate)
  local scale = target / referenceReward
  local modMultiplier = 1
  for _, mod in ipairs(item.modifiers or {}) do
    modMultiplier = modMultiplier * (mod.moneyMultipler or 1)
  end

  item.data = item.data or {}
  item.data.rewardFormulaVersion = 5
  item.data.logisticsPayRevision = balance.payRevision

  return baseReward * scale * parcelItemMoneyMultiplier * modMultiplier,
    minimumReward * scale, rewardPerKm * scale
end

-- Optional overrides: orgId adds reputation XP; orgMultiplier and economyMultiplier replace the live values.
function M.getXPReward(distance, slots, orgId, orgMultiplier, economyMultiplier)
  local baseXP, rules = getParcelBaseXP(slots)
  local xp = getParcelDistanceXP(distance, baseXP, rules)
  local rewards = {
    ["logistics-delivery"] = xp,
  }

  if orgId then
    local repDistance = xpConfig.applyRounding(distance / rules.reputationDistanceDivisor, rules.reputationDistanceRounding)
    rewards[orgId .. "Reputation"] = (baseXP + repDistance) * getProgressionMultiplier()

    -- Try to get org delivery bonus multiplier
    local appliedOrgMultiplier = orgMultiplier
    if not appliedOrgMultiplier then
      appliedOrgMultiplier = orgDeliveryBonus(overhaul_world_organizations.getOrganization(orgId))
    end
    if appliedOrgMultiplier then
      rewards.moneyMultiplier = appliedOrgMultiplier
    end
  end

  if economyMultiplier then
    rewards.economyMultiplier = economyMultiplier
  else
    rewards.economyMultiplier = overhaul_career_economyAdjuster.getSectionMultiplier("delivery_parcel")
  end

  return rewards
end

-- Combines money, XP, organization and economy into one complete rewards table.
function M.getParcelReward(item, distance, orgId, orgMultiplier, economyMultiplier)
  local baseXP, rules = getParcelBaseXP(item.slots)
  local xp = getParcelDistanceXP(distance, baseXP, rules)
  local money = M.getMoneyRewardForParcelItem(item, distance)

  local rewards = {
    money = money,
    ["logistics-delivery"] = xp,
  }

  if orgId then
    local repDistance = xpConfig.applyRounding(distance / rules.reputationDistanceDivisor, rules.reputationDistanceRounding)
    rewards[orgId .. "Reputation"] = (baseXP + repDistance) * getProgressionMultiplier()

    local appliedOrgMultiplier = orgMultiplier
    if not appliedOrgMultiplier then
      appliedOrgMultiplier = orgDeliveryBonus(overhaul_world_organizations.getOrganization(orgId))
    end
    if appliedOrgMultiplier then
      rewards.money = rewards.money * appliedOrgMultiplier
    end
  end

  local appliedEconomyMultiplier = economyMultiplier
  if not appliedEconomyMultiplier then
    appliedEconomyMultiplier = overhaul_career_economyAdjuster.getSectionMultiplier("delivery_parcel")
  end
  if appliedEconomyMultiplier then
    if type(rewards.economyBaseMoney) ~= "number" then
      rewards.economyBaseMoney = rewards.money
    end
    rewards.money = applyMoneyRounding(rewards.economyBaseMoney * appliedEconomyMultiplier)
    rewards.economyMultiplier = appliedEconomyMultiplier
  else
    rewards.economyMultiplier = 1
  end

  return rewards
end

-- Public API: vehicle and trailer offers ----------------------------------------------------------

-- filter carries baseReward and rewardPerKm; offerType is "vehicle" or "trailer". orgId adds reputation XP; economyMultiplier replaces the live section multiplier.
function M.getVehicleOfferReward(filter, distance, offerType, orgId, economyMultiplier)
  local rules = xpConfig.getVehicleRules()
  local moneyDistanceTerm = xpConfig.applyRounding((filter.rewardPerKm or 0) * distance / rules.moneyDistanceDivisor, rules.moneyDistanceRounding)
  local xpDistanceTerm = xpConfig.applyRounding(distance / rules.xpDistanceDivisor, rules.xpDistanceRounding)
  local deliveryBaseXP = rules.baseXP
  local trailerMoneyMultiplier = 1
  if offerType == "trailer" then
    deliveryBaseXP = getTrailerBaseXP(rules, filter)
    trailerMoneyMultiplier = getTrailerMoneyMultiplier(rules, filter)
  elseif offerType == "vehicle" then
    deliveryBaseXP = getVehicleBaseXP(rules, filter)
  end
  local isDistributorCar = filter and (filter.id == "newVehDistributorFilter"
    or filter.filterId == "newVehDistributorFilter"
    or filter.filterName == "New Vehicle (Distributor)")
  if isDistributorCar then deliveryBaseXP = tonumber(rules.carHaulBaseXP) or 1087 end
  local baseXP = deliveryBaseXP + xpDistanceTerm
  local target = isDistributorCar and balance.getCarHaulPay()
    or (offerType == "trailer" and balance.getTrailerPay(filter and filter.unlockTag)
      or balance.getVehiclePay(filter and filter.unlockTag))
  local money = balance.vehiclePayAtDistance(target, filter, distance, rules.moneyDistanceDivisor)
    or applyMoneyRounding(((filter.baseReward or 0) + moneyDistanceTerm) * trailerMoneyMultiplier)
  local rewards = {
    money = money,
    ["logistics-delivery"] = balance.roundXP(baseXP * getProgressionMultiplier()),
  }

  if orgId then
    local repDistance = xpConfig.applyRounding(distance / rules.reputationDistanceDivisor, rules.reputationDistanceRounding)
    rewards[orgId .. "Reputation"] = (deliveryBaseXP + repDistance) * getProgressionMultiplier()
  end

  local appliedEconomyMultiplier = economyMultiplier
  if not appliedEconomyMultiplier then
    local deliveryType = offerType == "vehicle" and "delivery_vehicle" or "delivery_trailer"
    appliedEconomyMultiplier = overhaul_career_economyAdjuster.getSectionMultiplier(deliveryType)
  end
  if appliedEconomyMultiplier then
    if type(rewards.economyBaseMoney) ~= "number" then
      rewards.economyBaseMoney = rewards.money
    end
    rewards.money = applyMoneyRounding(rewards.economyBaseMoney * appliedEconomyMultiplier)
    rewards.economyMultiplier = appliedEconomyMultiplier
  else
    rewards.economyMultiplier = 1
  end

  return rewards
end

-- Public API: material rewards (bulk batches) -----------------------------------------------------

function M.getMaterialMoneyPerKg(materialData)
  if not materialData then return 0 end
  local target, fullLoad = balance.getMaterialPay(materialData)
  local density = tonumber(materialData.density) or 0
  if target and fullLoad and density > 0 then
    return target / fullLoad / density / M.getMaterialRouteFactor(balance.referenceDistance)
  end
  if materialData.moneyPerKg ~= nil then
    return tonumber(materialData.moneyPerKg) or 0
  end
  if density <= 0 then return 0 end
  return (tonumber(materialData.money) or 0) / density
end

-- Distances are in metres. Nil keeps the neutral factor used by source cards before the player chooses a destination. Explicit routes scale linearly so every additional kilometre changes the payout.
function M.getMaterialRouteFactor(distance)
  if distance == nil then return 1 end
  local rules = xpConfig.getMaterialRules()
  local routeKm = math.max(0, (tonumber(distance) or 0) / 1000)
  return rules.moneyBaseFactor + rules.moneyFactorPerKm * routeKm
end

function M.getMaterialReward(materialData, amount, distance)
  local density = tonumber(materialData and materialData.density) or 0
  local cargoAmount = math.max(0, tonumber(amount) or 0)
  local target, fullLoad = balance.getMaterialPay(materialData)
  local baseReward = target and fullLoad and fullLoad > 0
    and (target * cargoAmount / fullLoad / M.getMaterialRouteFactor(balance.referenceDistance))
    or cargoAmount * density * M.getMaterialMoneyPerKg(materialData)
  return {
    money = baseReward * M.getMaterialRouteFactor(distance),
  }
end

-- Optional overrides: orgId adds reputation XP; orgMultiplier, economyMultiplier and materialType replace the live values; moneyReward is the base money the multipliers apply to.
function M.getMaterialXPReward(distance, slots, orgId, orgMultiplier, economyMultiplier, moneyReward, materialType)
  local rules = xpConfig.getMaterialRules()
  local materialBaseXP = getMaterialBaseXP(rules, materialType)
  local xpFormula = (materialBaseXP + math.max(0, (distance / rules.distanceDivisor) + rules.distanceOffset)) * (slots / rules.slotsDivisor)
  local xpAmount = balance.roundXP(xpConfig.applyRounding(xpFormula, rules.xpRounding) * getProgressionMultiplier())
  local rewards = {
    ["logistics-delivery"] = xpAmount,
  }

  local money = moneyReward and moneyReward * M.getMaterialRouteFactor(distance) or nil

  if orgId then
    rewards[orgId .. "Reputation"] = xpAmount

    local appliedOrgMultiplier = orgMultiplier
    if not appliedOrgMultiplier then
      appliedOrgMultiplier = orgDeliveryBonus(overhaul_world_organizations.getOrganization(orgId))
    end
    if appliedOrgMultiplier and money then
      money = money * appliedOrgMultiplier
    end
  end

  local appliedEconomyMultiplier = economyMultiplier
  if not appliedEconomyMultiplier then
    local deliveryType = "delivery_" .. (materialType or "fluid")
    appliedEconomyMultiplier = overhaul_career_economyAdjuster.getSectionMultiplier(deliveryType)
  end
  if appliedEconomyMultiplier and money then
    money = money * appliedEconomyMultiplier
  end

  if money then
    rewards.money = applyMoneyRounding(money)
  end
  rewards.economyMultiplier = appliedEconomyMultiplier or 1

  return rewards
end

-- Public API: hardcore and economy multipliers ----------------------------------------------------

function M.applyHardcoreMultiplier(reward, multiplier)
  return reward * (multiplier or getProgressionMultiplier())
end

-- The economy adjuster is a boot service, so it is called directly. Returns the adjusted reward and the multiplier used.
function M.applyEconomyAdjuster(reward, sectionKey)
  local multiplier = overhaul_career_economyAdjuster.getSectionMultiplier(sectionKey) or 1
  reward = reward * multiplier
  reward = applyMoneyRounding(reward)
  return reward, multiplier
end

-- Re-applies a new economy multiplier to an already-baked rewards table. The first rebake keeps the unrounded pre-multiplier money in economyBaseMoney. Returns true if money changed.
function M.rebakeRewardEconomy(rewards, newMultiplier)
  if type(rewards) ~= "table" or type(rewards.money) ~= "number" then return false end
  local previousMultiplier = tonumber(rewards.economyMultiplier) or 1
  if previousMultiplier < 1e-6 then previousMultiplier = 1 end
  newMultiplier = tonumber(newMultiplier) or 1
  if type(rewards.economyBaseMoney) ~= "number" then
    rewards.economyBaseMoney = rewards.money / previousMultiplier
  end
  if math.abs(previousMultiplier - newMultiplier) < 1e-6 then
    rewards.economyMultiplier = newMultiplier
    return false
  end
  rewards.money = applyMoneyRounding(rewards.economyBaseMoney * newMultiplier)
  rewards.economyMultiplier = newMultiplier
  return true
end

return M
