-- Shared delivery calculation functions
-- Extracted from career/modules/delivery/generator.lua
-- These are pure functions that do NOT require career mode to be active.

local M = {}

-- Mirror of the hardcoreMultiplier from generator.lua (default 1)
-- Caller can override via setHardcoreMultiplier()
local hardcoreMultiplier = 1

local parcelItemMoneyMultiplier = 1

function M.setHardcoreMultiplier(val)
  hardcoreMultiplier = val or 1
end

function M.getHardcoreMultiplier()
  return hardcoreMultiplier
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
  return ((basePrice) + math.pow(distance/1000, distanceExp) * pricePerM) * hardcoreMultiplier * parcelItemMoneyMultiplier * modMultiplier, basePrice, pricePerM
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
  local baseXP = 2
  if slots >= 16 then baseXP = baseXP + 1 end
  if slots >= 32 then baseXP = baseXP + 1 end
  if slots >= 64 then baseXP = baseXP + 1 end

  local xp = baseXP + round(distance/800) * hardcoreMultiplier
  local rewards = {
    logistics = xp,
    ["logistics-delivery"] = xp
  }

  -- Organization reputation and delivery bonus (from generator.lua ~line 175)
  if orgId then
    rewards[orgId .. "Reputation"] = baseXP + round(distance/1000)

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
  local baseXP = 2
  if item.slots >= 16 then baseXP = baseXP + 1 end
  if item.slots >= 32 then baseXP = baseXP + 1 end
  if item.slots >= 64 then baseXP = baseXP + 1 end

  local xp = baseXP + round(distance/800) * hardcoreMultiplier
  local money = M.getMoneyRewardForParcelItem(item, distance) * hardcoreMultiplier

  local rewards = {
    money = money,
    logistics = xp,
    ["logistics-delivery"] = xp
  }

  -- Organization reputation and delivery bonus (from generator.lua ~line 175)
  if orgId then
    rewards[orgId .. "Reputation"] = baseXP + round(distance/1000)

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
    rewards.money = math.floor(rewards.money * ecoMult + 0.5)
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
  local rewards = {
    money = (filter.baseReward + round(filter.rewardPerKm * distance/1000)) * hardcoreMultiplier,
    logistics = (5 + round(distance/400)) * hardcoreMultiplier
  }
  if offerType == "vehicle" then
    rewards.money = rewards.money * hardcoreMultiplier
    rewards["logistics-vehicleDelivery"] = (5 + round(distance/400)) * hardcoreMultiplier
  elseif offerType == "trailer" then
    rewards.money = rewards.money * hardcoreMultiplier
    rewards["logistics-delivery"] = (5 + round(distance/400)) * hardcoreMultiplier
  end

  -- Organization reputation (from generator.lua ~line 556)
  if orgId then
    rewards[orgId .. "Reputation"] = (5 + round(distance/4000)) * hardcoreMultiplier
  end

  -- Economy adjuster (from generator.lua ~line 559)
  local ecoMult = economyMultiplier
  if not ecoMult and career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
    local deliveryType = offerType == "vehicle" and "delivery_vehicle" or "delivery_trailer"
    ecoMult = career_economyAdjuster.getSectionMultiplier(deliveryType)
  end
  if ecoMult then
    rewards.money = math.floor(rewards.money * ecoMult + 0.5)
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
  local xpAmount = round((3+math.max(0,(distance/2000)-1)) * (slots / 400)) * hardcoreMultiplier
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
      money = money * appliedOrgMultiplier * hardcoreMultiplier
    end
  end

  -- Economy adjuster (from generator.lua ~line 1091)
  local ecoMult = economyMultiplier
  if not ecoMult and career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
    local deliveryType = "delivery_" .. (materialType or "fluid")
    ecoMult = career_economyAdjuster.getSectionMultiplier(deliveryType)
  end
  if ecoMult and money then
    money = math.floor(money * ecoMult + 0.5)
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
  return reward * (multiplier or hardcoreMultiplier)
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
    reward = math.floor(reward + 0.5) -- Round to nearest integer
  end
  return reward
end

return M
