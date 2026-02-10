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
  local modMultiplier = 1---0.9 + 0.1 * #item.modifiers
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
function M.getXPReward(distance, slots)
  local baseXP = 2
  if slots >= 16 then baseXP = baseXP + 1 end
  if slots >= 32 then baseXP = baseXP + 1 end
  if slots >= 64 then baseXP = baseXP + 1 end

  return baseXP + round(distance/800) * hardcoreMultiplier
end

-------------------------------
-- Vehicle/Trailer Offer Reward
-------------------------------
-- Exact copy from finalizeVehicleOffer ~line 425
-- filter must have .baseReward and .rewardPerKm fields
-- offerType is "vehicle" or "trailer"
function M.getVehicleOfferReward(filter, distance, offerType)
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
function M.getMaterialXPReward(distance, slots)
  return round((3+math.max(0,(distance/2000)-1)) * (slots / 400)) * hardcoreMultiplier
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
