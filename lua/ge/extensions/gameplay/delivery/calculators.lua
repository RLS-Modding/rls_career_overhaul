-- Shared delivery calculation functions
-- Extracted from career/modules/delivery/generator.lua
-- These are pure functions that do NOT require career mode to be active.

local M = {}
local xpConfig = require('gameplay/delivery/logisticsXPConfig')

local legacyHardcoreMultiplier = 1

local function getProgressionMultiplier()
  if career_modules_difficultyMode and career_modules_difficultyMode.getXPMultiplier then
    return career_modules_difficultyMode.getXPMultiplier()
  end
  return legacyHardcoreMultiplier
end

local parcelItemMoneyMultiplier = 1

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
  trailerDolly = "dryvan",
  trailerDryvan = "dryvan",
  emptyLargeTrailer = "flatbed",
  loadedLargeTrailers = "flatbed",
  trailerFlatbed = "flatbed",
  trailerFramelessDump = "flatbed",
  trailerTanker = "tanker",
  trailerContainer = "container",
  trailerLogTrailer = "log"
}

local TRAILER_XP_LEVEL_BY_GROUP = {
  small = 5,
  medium = 17,
  dryvan = 25,
  flatbed = 30,
  tanker = 35,
  container = 37,
  log = 40
}

local VEHICLE_XP_TAGS = {
  junkerVeh = true,
  smallVeh = true,
  fleetVeh = true,
  highEndVeh = true,
  exoticVeh = true,
  heavyVeh = true,
  largeVeh = true
}

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
  return (baseXP + distanceTerm) * getProgressionMultiplier()
end

function M.setHardcoreMultiplier(val)
  legacyHardcoreMultiplier = val or 1
end

function M.getHardcoreMultiplier()
  return legacyHardcoreMultiplier
end

function M.setParcelItemMoneyMultiplier(val)
  parcelItemMoneyMultiplier = val or 1
end

-------------------------------
-- Parcel Money Reward
-------------------------------
-- Exact copy from generator.lua ~line 147
function M.getMoneyRewardForParcelItem(item, distance)
  local basePrice = math.sqrt(item.slots) / 4
  local distanceExp = 1.3 + math.sqrt(item.slots)/100
  local pricePerM = 5 + math.pow(item.weight, 0.9)
  local modMultiplier = 1
  for _, mod in ipairs(item.modifiers) do
    modMultiplier = modMultiplier * (mod.moneyMultipler or 1)
  end

  -- cleanup
  return ((basePrice) + math.pow(distance/1000, distanceExp) * pricePerM) * parcelItemMoneyMultiplier * modMultiplier, basePrice, pricePerM
end

-------------------------------
-- Parcel XP Reward
-------------------------------
-- Exact copy from finalizeParcelItemDistanceAndRewards ~line 160
-- Optional params:
--   orgId: organization id string (adds org reputation XP)
--   orgMultiplier: override for org delivery bonus money multiplier
--   economyMultiplier: override for economy adjuster multiplier
function M.getXPReward(distance, slots, orgId, orgMultiplier, economyMultiplier)
  local baseXP, rules = getParcelBaseXP(slots)
  local xp = getParcelDistanceXP(distance, baseXP, rules)
  local rewards = {
    logistics = xp,
    ["logistics-delivery"] = xp
  }

  -- Organization reputation and delivery bonus (from generator.lua ~line 175)
  if orgId then
    local repDistance = xpConfig.applyRounding(distance / rules.reputationDistanceDivisor, rules.reputationDistanceRounding)
    rewards[orgId .. "Reputation"] = (baseXP + repDistance) * getProgressionMultiplier()

    -- Try to get org delivery bonus multiplier
    local appliedOrgMultiplier = orgMultiplier
    if not appliedOrgMultiplier and freeroam_organizations and freeroam_organizations.getOrganization then
      local organizationData = freeroam_organizations.getOrganization(orgId)
      if organizationData then
        appliedOrgMultiplier = organizationData.reputationLevels[organizationData.reputation.level+2].deliveryBonus.value
      end
    end
    if appliedOrgMultiplier then
      rewards.moneyMultiplier = appliedOrgMultiplier
    end
  end

  -- Economy adjuster (from generator.lua ~line 182)
  if economyMultiplier then
    rewards.economyMultiplier = economyMultiplier
  elseif career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
    rewards.economyMultiplier = career_economyAdjuster.getSectionMultiplier("delivery_parcel")
  end

  return rewards
end

-------------------------------
-- Parcel Full Reward
-------------------------------
-- Combines money + XP + org + economy into a complete rewards table.
-- This mirrors the full finalizeParcelItemDistanceAndRewards from generator.lua.
function M.getParcelReward(item, distance, orgId, orgMultiplier, economyMultiplier)
  local baseXP, rules = getParcelBaseXP(item.slots)
  local xp = getParcelDistanceXP(distance, baseXP, rules)
  local money = M.getMoneyRewardForParcelItem(item, distance)

  local rewards = {
    money = money,
    logistics = xp,
    ["logistics-delivery"] = xp
  }

  -- Organization reputation and delivery bonus (from generator.lua ~line 175)
  if orgId then
    local repDistance = xpConfig.applyRounding(distance / rules.reputationDistanceDivisor, rules.reputationDistanceRounding)
    rewards[orgId .. "Reputation"] = (baseXP + repDistance) * getProgressionMultiplier()

    local appliedOrgMultiplier = orgMultiplier
    if not appliedOrgMultiplier and freeroam_organizations and freeroam_organizations.getOrganization then
      local organizationData = freeroam_organizations.getOrganization(orgId)
      if organizationData then
        appliedOrgMultiplier = organizationData.reputationLevels[organizationData.reputation.level+2].deliveryBonus.value
      end
    end
    if appliedOrgMultiplier then
      rewards.money = rewards.money * appliedOrgMultiplier
    end
  end

  -- Economy adjuster (from generator.lua ~line 182)
  local ecoMult = economyMultiplier
  if not ecoMult and career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
    ecoMult = career_economyAdjuster.getSectionMultiplier("delivery_parcel")
  end
  if ecoMult then
    rewards.money = applyMoneyRounding(rewards.money * ecoMult)
  end

  return rewards
end

-------------------------------
-- Vehicle/Trailer Offer Reward
-------------------------------
-- Exact copy from finalizeVehicleOffer ~line 425
-- filter must have .baseReward and .rewardPerKm fields
-- offerType is "vehicle" or "trailer"
-- Optional params:
--   orgId: organization id string (adds org reputation XP)
--   economyMultiplier: override for economy adjuster multiplier
function M.getVehicleOfferReward(filter, distance, offerType, orgId, economyMultiplier)
  local rules = xpConfig.getVehicleRules()
  local moneyDistanceTerm = xpConfig.applyRounding((filter.rewardPerKm or 0) * distance / rules.moneyDistanceDivisor, rules.moneyDistanceRounding)
  local xpDistanceTerm = xpConfig.applyRounding(distance / rules.xpDistanceDivisor, rules.xpDistanceRounding)
  local deliveryBaseXP = rules.baseXP
  if offerType == "trailer" then
    deliveryBaseXP = getTrailerBaseXP(rules, filter)
  elseif offerType == "vehicle" then
    deliveryBaseXP = getVehicleBaseXP(rules, filter)
  end
  local baseXP = deliveryBaseXP + xpDistanceTerm
  local rewards = {
    money = (filter.baseReward or 0) + moneyDistanceTerm,
    logistics = baseXP * getProgressionMultiplier()
  }
  if offerType == "vehicle" then
    rewards["logistics-delivery"] = baseXP * getProgressionMultiplier()
  elseif offerType == "trailer" then
    rewards["logistics-delivery"] = baseXP * getProgressionMultiplier()
  end

  -- Organization reputation (from generator.lua ~line 556)
  if orgId then
    local repDistance = xpConfig.applyRounding(distance / rules.reputationDistanceDivisor, rules.reputationDistanceRounding)
    rewards[orgId .. "Reputation"] = (deliveryBaseXP + repDistance) * getProgressionMultiplier()
  end

  -- Economy adjuster (from generator.lua ~line 559)
  local ecoMult = economyMultiplier
  if not ecoMult and career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
    local deliveryType = offerType == "vehicle" and "delivery_vehicle" or "delivery_trailer"
    ecoMult = career_economyAdjuster.getSectionMultiplier(deliveryType)
  end
  if ecoMult then
    rewards.money = applyMoneyRounding(rewards.money * ecoMult)
  end

  return rewards
end

-------------------------------
-- Material Reward (new material parcel)
-------------------------------
-- Exact copy from addMaterialAsParcelToContainer ~line 530
-- materialData must have .money field
function M.getMaterialReward(materialData, amount)
  return {
    money = amount * materialData.money,
  }
end

-------------------------------
-- Material Distance XP Reward
-------------------------------
-- Exact copy from finalizeMaterialDistanceRewards ~line 605
-- (3+(max(0,($D24/2000)-1))) * (E$23/400)
-- Optional params:
--   orgId: organization id string (adds org reputation XP)
--   orgMultiplier: override for org delivery bonus money multiplier
--   economyMultiplier: override for economy adjuster multiplier
--   moneyReward: base money reward to apply org/economy multipliers to
--   materialType: material type string for economy adjuster section key (e.g. "fluid", "dryBulk")
function M.getMaterialXPReward(distance, slots, orgId, orgMultiplier, economyMultiplier, moneyReward, materialType)
  local rules = xpConfig.getMaterialRules()
  local materialBaseXP = getMaterialBaseXP(rules, materialType)
  local xpFormula = (materialBaseXP + math.max(0, (distance / rules.distanceDivisor) + rules.distanceOffset)) * (slots / rules.slotsDivisor)
  local xpAmount = xpConfig.applyRounding(xpFormula, rules.xpRounding) * getProgressionMultiplier()
  local rewards = {
    logistics = xpAmount,
    ["logistics-delivery"] = xpAmount
  }

  local money = moneyReward

  -- Organization reputation and delivery bonus (from generator.lua ~line 1082)
  if orgId then
    rewards[orgId .. "Reputation"] = xpAmount

    local appliedOrgMultiplier = orgMultiplier
    if not appliedOrgMultiplier and freeroam_organizations and freeroam_organizations.getOrganization then
      local organizationData = freeroam_organizations.getOrganization(orgId)
      if organizationData then
        appliedOrgMultiplier = organizationData.reputationLevels[organizationData.reputation.level+2].deliveryBonus.value
      end
    end
    if appliedOrgMultiplier and money then
      money = money * appliedOrgMultiplier
    end
  end

  -- Economy adjuster (from generator.lua ~line 1091)
  local ecoMult = economyMultiplier
  if not ecoMult and career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
    local deliveryType = "delivery_" .. (materialType or "fluid")
    ecoMult = career_economyAdjuster.getSectionMultiplier(deliveryType)
  end
  if ecoMult and money then
    money = applyMoneyRounding(money * ecoMult)
  end

  if money then
    rewards.money = money
  end

  return rewards
end

-------------------------------
-- Hardcore Multiplier
-------------------------------
function M.applyHardcoreMultiplier(reward, multiplier)
  return reward * (multiplier or getProgressionMultiplier())
end

-------------------------------
-- Economy Adjuster (safe)
-------------------------------
-- Safely checks if career_economyAdjuster exists before using it.
-- Falls back to returning the reward unchanged.
function M.applyEconomyAdjuster(reward, sectionKey)
  if career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
    local multiplier = career_economyAdjuster.getSectionMultiplier(sectionKey)
    reward = reward * multiplier
    reward = applyMoneyRounding(reward)
  end
  return reward
end

return M
