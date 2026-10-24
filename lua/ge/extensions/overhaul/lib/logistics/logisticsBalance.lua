-- Four-mile, one-way logistics pay targets from the existing balance sheet.
-- Read base targets, trailer adjustments, then the public pay projections.
local M = {}

M.referenceDistance = 4 * 1609.344
M.basePayMultiplier = 1.5
M.payRevision = 2

local trailerPay = {
  emptySmallTrailers = 750, loadedSmallTrailers = 750,
  trailerBoxutility = 750, trailerBoxutilityLarge = 750,
  trailerTsfb = 750, trailerCaravan = 750,
  emptyMediumTrailers = 1500, loadedMediumTrailers = 1500,
  trailerCargotrailer = 1500, trailerTiltdeck = 1500,
  trailerHeavyHitch = 3000,
  trailerDolly = 4000, trailerDryvan = 4000,
  emptyLargeTrailer = 4250, loadedLargeTrailers = 4250,
  trailerFlatbed = 4250,
  trailerFramelessDump = 4550,
  trailerTanker = 4700,
  trailerContainer = 4850,
  trailerLogTrailer = 5000,
}

local vehiclePay = {
  junkerVeh = 500, smallVeh = 750, fleetVeh = 1250,
  highEndVeh = 2000, largeVeh = 2000,
  exoticVeh = 3250, heavyVeh = 4000,
}

local parcelPay = { [16] = 25, [32] = 50, [64] = 100, [128] = 200 }
-- Economic rewardWeight is distinct from the parcel's physical vehicle mass. Generation-chance weighted authored reward weights, rounded from parcel templates.
local parcelReferenceWeight = { [16] = 1.6, [32] = 4.2, [64] = 8.3, [128] = 144.3 }
local materialPay = { cash = 5000, cement = 6500, dryBulk = 7500, fluid = 7500 }
-- Largest compatible vehicle capacities, not contract batch sizes that may need several deliveries.
local materialLoad = { cash = 600, coin = 600, gold = 600,
  cement = 12000, dryBulk = 30000, fluid = 17700 }

local function round(value)
  return math.floor((tonumber(value) or 0) + 0.5)
end

function M.getLevelBonus(level)
  return math.max(0, math.min(20, math.floor(tonumber(level) or 1) - 30)) * 0.05
end

function M.applyLevelBonus(amount, level)
  return round((tonumber(amount) or 0) * (1 + M.getLevelBonus(level)))
end

function M.scaleBasePay(amount)
  return amount and amount * M.basePayMultiplier or nil
end

-- Unaccepted saved listings get the new base pay once; XP and in-progress quotes stay as saved.
function M.scaleSavedOfferRewards(rewards)
  if type(rewards) ~= "table" or type(rewards.money) ~= "number" then return false end
  rewards.money = M.scaleBasePay(rewards.money)
  if type(rewards.economyBaseMoney) == "number" then
    rewards.economyBaseMoney = M.scaleBasePay(rewards.economyBaseMoney)
  end
  return true
end

function M.getTrailerPay(tag) return M.scaleBasePay(trailerPay[tag]) end
function M.getVehiclePay(tag) return M.scaleBasePay(vehiclePay[tag]) end
function M.getCarHaulPay() return M.scaleBasePay(1750) end

function M.getParcelTier(slots)
  slots = math.max(1, tonumber(slots) or 1)
  if slots <= 16 then return 16 end
  if slots <= 32 then return 32 end
  if slots <= 64 then return 64 end
  return 128
end

function M.getParcelPay(slots)
  local tier = M.getParcelTier(slots)
  return M.scaleBasePay(parcelPay[tier]), parcelReferenceWeight[tier]
end

function M.getMaterialPay(materialData)
  local kind = materialData and materialData.type
  local target = materialPay[kind]
  if not target then return nil end
  local name = string.lower(tostring(materialData.name or materialData.id or ""))
  local load = materialLoad[kind]
  if kind == "cash" then
    if name:find("coin", 1, true) then load = materialLoad.coin end
    if name:find("gold", 1, true) then load = materialLoad.gold end
  end
  return M.scaleBasePay(target), load
end

-- Each filter keeps its distance curve, while every variant in a tier meets the same four-mile target.
function M.vehiclePayAtDistance(target, filter, distance, divisor)
  if not target then return nil end
  local base = tonumber(filter and filter.baseReward) or 0
  local perKm = tonumber(filter and filter.rewardPerKm) or 0
  divisor = tonumber(divisor) or 1000
  local reference = base + round(perKm * M.referenceDistance / divisor)
  local current = base + round(perKm * math.max(0, tonumber(distance) or 0) / divisor)
  if reference <= 0 then return round(target) end
  return round(target * current / reference)
end

function M.roundXP(value)
  if not value or value <= 0 then return 0 end
  local step = value < 500 and 10 or 50
  return step * round(value / step)
end

return M
