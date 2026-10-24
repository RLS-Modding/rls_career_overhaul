-- Persistent property owners, price adjustments and seller profiles.
-- Read tuning, NPC creation, willingness and pricing, owner projections, updates, then save/load hooks.
local M = {}

-- Config ------------------------------------------------------------------------------------------

local SAVE_FILE = "propertyOwners.json"
local SAVE_SUBDIR = "/career/rls_career"

local tuning = {
  refreshIntervalS = 120,
  updatePollIntervalS = 5,
  freshOwnershipS = 300,
  longOwnershipS = 3600,
  npcIdMin = 1000,
  npcIdMax = 9999,
  buyingTendencyMinFraction = 0.4,
  buyingTendencyMaxFraction = 0.9,
  sellingTendencyMinFraction = 0.35,
  sellingTendencyMaxFraction = 0.85,
  homeownerAttachmentMinFraction = 0.6,
  homeownerAttachmentMaxFraction = 0.95,
  otherAttachmentMinFraction = 0.15,
  otherAttachmentMaxFraction = 0.55,
  defaultWillingnessFraction = 0.5,
  freshWillingnessDropFraction = 0.45,
  moderateWillingnessDeltaFraction = 0.0,
  longWillingnessGainFraction = 0.2,
  cashStrappedMarketThreshold = 0.95,
  cashStrappedWillingnessGainFraction = 0.2,
  homeownerFreshWillingnessDropFraction = 0.2,
  lowMarketThreshold = 0.85,
  highMarketThreshold = 1.1,
  lowMarketWillingnessDropFraction = 0.05,
  highMarketWillingnessGainFraction = 0.07,
  minWillingnessFraction = 0.02,
  maxWillingnessFraction = 0.98,
  freshMarkupGainFraction = 0.18,
  longMarkupDropFraction = 0.05,
  distressedMarketThreshold = 0.9,
  distressedMarkupDropFraction = 0.12,
  marketMarkupWeight = 0.5,
  minAskingPriceMoney = 1000,
  developerMarketThreshold = 0.8,
  developerPriceFloorTriggerFraction = 0.9,
  developerPriceFloorFraction = 0.95,
  initialWillingnessFraction = 0.1,
  defaultPatienceFraction = 0.5,
  fallbackMarketPriceMoney = 100000,
  fallbackPriceMinFraction = 0.95,
  fallbackPriceMaxFraction = 1.15,
  bankWillingnessFraction = 0.65,
  bankPatienceFraction = 0.55,
  otherPatienceFraction = 0.7,
  minAdjustmentFrequencyMultiplier = 0.25,
}

local ARCHETYPES = {
  investor = {
    markupMin = 0.08,
    markupMax = 0.22,
    adjustmentFrequencyMult = 1.5,
    adjustmentAggression = 1.35,
    patienceMin = 0.35,
    patienceMax = 0.6,
    baseWillingness = 0.55,
    priceSensitivity = 1.1,
  },
  homeowner = {
    markupMin = 0.12,
    markupMax = 0.3,
    adjustmentFrequencyMult = 0.6,
    adjustmentAggression = 0.65,
    patienceMin = 0.6,
    patienceMax = 0.85,
    baseWillingness = 0.35,
    priceSensitivity = 0.7,
  },
  cash_strapped = {
    markupMin = 0.02,
    markupMax = 0.14,
    adjustmentFrequencyMult = 1.2,
    adjustmentAggression = 1.2,
    patienceMin = 0.3,
    patienceMax = 0.55,
    baseWillingness = 0.7,
    priceSensitivity = 1.4,
  },
  developer = {
    markupMin = 0.1,
    markupMax = 0.28,
    adjustmentFrequencyMult = 1.0,
    adjustmentAggression = 1.1,
    patienceMin = 0.45,
    patienceMax = 0.7,
    baseWillingness = 0.5,
    priceSensitivity = 1.0,
  },
}

local DEFAULT_SELLER_TYPES = { "bank", "developer", "original_owner" }
local ARCHETYPE_KEYS = { "investor", "homeowner", "cash_strapped", "developer" }

local OWNER_GROUPS = {
  investor = {
    "Pinnacle Property Group",
    "Summit Capital Partners",
    "Northbridge Real Estate Holdings",
    "Meridian Equity Group",
    "Ridgeview Asset Management",
  },
  homeowner = {
    "Thompson Family",
    "Miller Family",
    "Carter Family",
    "Harrington Family",
    "Bennett Family",
  },
  cash_strapped = {
    "Riverside Property Trust",
    "Harborline Recovery Holdings",
    "Northline Distressed Assets",
    "Cobalt Family Estates",
    "Cedar Street Investors",
  },
  developer = {
    "Hawthorne Development Group",
    "Crosswind Developers",
    "Stonebridge Development",
    "Urban Crest Developers",
    "Evergreen Property Builders",
  },
}

-- State -------------------------------------------------------------------------------------------

local ownersByGarageId = {}
local npcRoster = {}
local updateAccumulator = 0
local ownershipTime = 0

-- Shared helpers ----------------------------------------------------------------------------------

local function clamp(v, minV, maxV)
  if v < minV then return minV end
  if v > maxV then return maxV end
  return v
end

local function randomBetween(minV, maxV)
  return minV + (math.random() * (maxV - minV))
end

local function getCurrentTime()
  return ownershipTime
end

local function getHousingMarketIndex()
  return overhaul_career_economy_globalEconomy.getHousingMarketIndex() or 1
end

local function getDurationBucket(purchaseTime)
  local ownedSeconds = math.max(0, getCurrentTime() - (purchaseTime or getCurrentTime()))
  if ownedSeconds < tuning.freshOwnershipS then
    return "fresh", ownedSeconds
  elseif ownedSeconds < tuning.longOwnershipS then
    return "moderate", ownedSeconds
  end
  return "long", ownedSeconds
end

-- NPC roster --------------------------------------------------------------------------------------

local function generateOwnerName(archetype)
  local names = OWNER_GROUPS[archetype] or OWNER_GROUPS.investor
  if not names or #names == 0 then
    names = OWNER_GROUPS.investor
  end
  return names[math.random(1, #names)]
end

local function chooseArchetype()
  return ARCHETYPE_KEYS[math.random(1, #ARCHETYPE_KEYS)]
end

local function createNpcRecord(name, archetype)
  local archetypeData = ARCHETYPES[archetype] or ARCHETYPES.investor
  local npcId = string.format("npc_%d_%d", getCurrentTime(), math.random(tuning.npcIdMin, tuning.npcIdMax))
  local record = {
    npcId = npcId,
    name = name or generateOwnerName(archetype),
    archetype = archetype,
    traits = {
      buyingTendency = randomBetween(tuning.buyingTendencyMinFraction, tuning.buyingTendencyMaxFraction),
      sellingTendency = randomBetween(tuning.sellingTendencyMinFraction, tuning.sellingTendencyMaxFraction),
      priceSensitivity = archetypeData.priceSensitivity,
      patienceProfile = randomBetween(archetypeData.patienceMin, archetypeData.patienceMax),
      adjustmentAggression = archetypeData.adjustmentAggression,
      adjustmentFrequencyMult = archetypeData.adjustmentFrequencyMult,
      emotionalAttachment = archetype == "homeowner" and randomBetween(tuning.homeownerAttachmentMinFraction, tuning.homeownerAttachmentMaxFraction) or randomBetween(tuning.otherAttachmentMinFraction, tuning.otherAttachmentMaxFraction),
    },
  }
  npcRoster[npcId] = record
  return record
end

local function findOrCreateNpcFromBuyer(buyerPersonality)
  if type(buyerPersonality) ~= "table" then
    return createNpcRecord(nil, chooseArchetype())
  end

  local name = buyerPersonality.name or generateOwnerName(buyerPersonality.archetype)
  local archetype = buyerPersonality.archetype
  if archetype == "cash-strapped" then archetype = "cash_strapped" end
  if not ARCHETYPES[archetype] then
    archetype = chooseArchetype()
    name = buyerPersonality.name or generateOwnerName(archetype)
  end

  for _, record in pairs(npcRoster) do
    if record and record.name == name and record.archetype == archetype then
      return record
    end
  end

  return createNpcRecord(name, archetype)
end

-- Willingness and pricing -------------------------------------------------------------------------

local function calculateWillingness(ownerData)
  if not ownerData then return tuning.defaultWillingnessFraction end
  local archetypeData = ARCHETYPES[ownerData.archetype] or ARCHETYPES.investor
  local marketIndex = getHousingMarketIndex()
  local durationBucket = getDurationBucket(ownerData.purchaseTime)

  local willingness = archetypeData.baseWillingness

  if durationBucket == "fresh" then
    willingness = willingness - tuning.freshWillingnessDropFraction
  elseif durationBucket == "moderate" then
    willingness = willingness + tuning.moderateWillingnessDeltaFraction
  else
    willingness = willingness + tuning.longWillingnessGainFraction
  end

  if ownerData.archetype == "cash_strapped" and marketIndex < tuning.cashStrappedMarketThreshold then
    willingness = willingness + tuning.cashStrappedWillingnessGainFraction
  end

  if ownerData.archetype == "homeowner" and durationBucket == "fresh" then
    willingness = willingness - tuning.homeownerFreshWillingnessDropFraction
  end

  if marketIndex < tuning.lowMarketThreshold then
    willingness = willingness - tuning.lowMarketWillingnessDropFraction
  elseif marketIndex > tuning.highMarketThreshold then
    willingness = willingness + tuning.highMarketWillingnessGainFraction
  end

  return clamp(willingness, tuning.minWillingnessFraction, tuning.maxWillingnessFraction)
end

local function calculateAskingPrice(ownerData, basePrice)
  if not ownerData then return basePrice or 0 end
  local archetypeData = ARCHETYPES[ownerData.archetype] or ARCHETYPES.investor
  local marketIndex = getHousingMarketIndex()
  local purchasePrice = ownerData.purchasePrice or basePrice or 0
  local durationBucket = getDurationBucket(ownerData.purchaseTime)
  local baseMarkup = randomBetween(archetypeData.markupMin, archetypeData.markupMax)

  if durationBucket == "fresh" then
    baseMarkup = baseMarkup + tuning.freshMarkupGainFraction
  elseif durationBucket == "long" then
    baseMarkup = baseMarkup - tuning.longMarkupDropFraction
  end

  if ownerData.archetype == "cash_strapped" and marketIndex < tuning.distressedMarketThreshold and durationBucket == "long" then
    baseMarkup = baseMarkup - tuning.distressedMarkupDropFraction
  end

  local marketBias = (marketIndex - 1) * tuning.marketMarkupWeight
  local ask = math.floor(math.max(tuning.minAskingPriceMoney, purchasePrice * (1 + baseMarkup + marketBias)) + 0.5)

  if ownerData.archetype == "developer" and marketIndex < tuning.developerMarketThreshold and ask < purchasePrice * tuning.developerPriceFloorTriggerFraction then
    ask = math.floor(purchasePrice * tuning.developerPriceFloorFraction + 0.5)
  end

  return math.max(tuning.minAskingPriceMoney, ask)
end

-- Owner records -----------------------------------------------------------------------------------

local function buildOwnerDataFromNpc(npc, garageId, purchasePrice)
  local now = getCurrentTime()
  local ownerData = {
    npcId = npc.npcId,
    garageId = garageId,
    name = npc.name,
    archetype = npc.archetype,
    purchasePrice = purchasePrice,
    purchaseTime = now,
    currentAskingPrice = purchasePrice,
    willingnessToSell = tuning.initialWillingnessFraction,
    patienceProfile = npc.traits and npc.traits.patienceProfile or tuning.defaultPatienceFraction,
    priceSensitivity = npc.traits and npc.traits.priceSensitivity or 1,
    traits = npc.traits or {},
    lastAdjustmentTime = now,
  }

  ownerData.currentAskingPrice = calculateAskingPrice(ownerData, purchasePrice)
  ownerData.willingnessToSell = calculateWillingness(ownerData)
  return ownerData
end

local function registerOwnerFromSale(garageId, purchasePrice, buyerPersonality)
  if not garageId or not purchasePrice or purchasePrice <= 0 then return false end
  local npc = findOrCreateNpcFromBuyer(buyerPersonality)
  if not npc then return false end

  ownersByGarageId[garageId] = buildOwnerDataFromNpc(npc, garageId, purchasePrice)
  return true
end

local function clearOwner(garageId)
  if not garageId then return false end
  ownersByGarageId[garageId] = nil
  return true
end

local function getOwner(garageId)
  if not garageId then return nil end
  return ownersByGarageId[garageId]
end

local function ensureOwnerForGarage(garageId, fallbackPrice)
  if not garageId then return nil end

  local purchasePrice = tonumber(fallbackPrice) or 0
  if purchasePrice <= 0 then
    return nil
  end

  local owner = getOwner(garageId)
  if owner then
    return owner
  end

  local npc = findOrCreateNpcFromBuyer()
  if not npc then return nil end

  local newOwner = buildOwnerDataFromNpc(npc, garageId, purchasePrice)
  ownersByGarageId[garageId] = newOwner
  return newOwner
end

local function ownerPresentation(owner)
  return {
    name = owner.name,
    archetype = owner.archetype,
    willingnessToSell = owner.willingnessToSell,
    traits = owner.traits,
  }
end

local function getOwnerForListing(garageId, fallbackPrice)
  local owner = ensureOwnerForGarage(garageId, fallbackPrice)
  if not owner then return nil end

  owner.willingnessToSell = calculateWillingness(owner)
  if not owner.currentAskingPrice then
    owner.currentAskingPrice = calculateAskingPrice(owner, fallbackPrice or owner.purchasePrice)
  end

  local listing = ownerPresentation(owner)
  listing.garageId = garageId
  listing.currentAskingPrice = owner.currentAskingPrice
  listing.purchasePrice = owner.purchasePrice
  listing.purchaseTime = owner.purchaseTime
  listing.patienceProfile = owner.patienceProfile
  return listing
end

local function buildFallbackSellerProfile(fallbackMarketPrice)
  local sellerType = DEFAULT_SELLER_TYPES[math.random(1, #DEFAULT_SELLER_TYPES)]
  local startingPrice = math.max(tuning.minAskingPriceMoney, math.floor((fallbackMarketPrice or tuning.fallbackMarketPriceMoney) * randomBetween(tuning.fallbackPriceMinFraction, tuning.fallbackPriceMaxFraction) + 0.5))
  return {
    source = "fallback",
    sellerType = sellerType,
    name = sellerType == "bank" and "Foreclosure Officer" or (sellerType == "developer" and "Regional Developer" or "Original Owner"),
    archetype = sellerType == "developer" and "developer" or "homeowner",
    startingPrice = startingPrice,
    willingnessToSell = sellerType == "bank" and tuning.bankWillingnessFraction or tuning.defaultWillingnessFraction,
    patience = sellerType == "bank" and tuning.bankPatienceFraction or tuning.otherPatienceFraction,
    isPersistentOwner = false,
  }
end

local function getSellerProfileForNegotiation(garageId, fallbackMarketPrice)
  local owner = ensureOwnerForGarage(garageId, fallbackMarketPrice)
  if not owner then
    return buildFallbackSellerProfile(fallbackMarketPrice)
  end

  local seller = ownerPresentation(owner)
  seller.source = "owner"
  seller.garageId = garageId
  seller.startingPrice = owner.currentAskingPrice
  seller.patience = owner.patienceProfile
  seller.isPersistentOwner = true
  return seller
end

local function refreshOwner(ownerData)
  if not ownerData then return end
  local now = getCurrentTime()
  local archetypeData = ARCHETYPES[ownerData.archetype] or ARCHETYPES.investor
  local cadence = tuning.refreshIntervalS / math.max(tuning.minAdjustmentFrequencyMultiplier, archetypeData.adjustmentFrequencyMult or 1)

  if now - (ownerData.lastAdjustmentTime or 0) < cadence then return end

  ownerData.lastAdjustmentTime = now
  ownerData.willingnessToSell = calculateWillingness(ownerData)
  ownerData.currentAskingPrice = calculateAskingPrice(ownerData, ownerData.purchasePrice)
end

-- Update ------------------------------------------------------------------------------------------

local function onUpdate(dtReal, dtSim)
  if not overhaul_career_career.isActive() then return end
  ownershipTime = ownershipTime + math.max(0, tonumber(dtReal) or 0)
  updateAccumulator = updateAccumulator + (dtReal or 0)
  if updateAccumulator < tuning.updatePollIntervalS then return end
  updateAccumulator = 0

  for _, ownerData in pairs(ownersByGarageId) do
    refreshOwner(ownerData)
  end
end

-- Save and load -----------------------------------------------------------------------------------

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if not currentSavePath then
    local _, path = overhaul_career_saveSystem.getCurrentProfile()
    currentSavePath = path
    if not currentSavePath then return end
  end

  local dirPath = currentSavePath .. SAVE_SUBDIR
  if not writer.exists(dirPath) then
    writer.mkdir(dirPath)
  end

  overhaul_career_saveSystem.jsonWriteFileSafe(dirPath .. "/" .. SAVE_FILE, {
    ownersByGarageId = ownersByGarageId,
    npcRoster = npcRoster,
    ownershipTime = ownershipTime,
  }, true)
end

-- Saves from before the clock was stored resume from the newest owner timestamp.
local function latestOwnerActivityTime()
  local latest = 0
  for _, owner in pairs(ownersByGarageId) do
    latest = math.max(latest, tonumber(owner.lastAdjustmentTime) or tonumber(owner.purchaseTime) or 0)
  end
  return latest
end

local function loadOwners()
  if not overhaul_career_career.isActive() then return end

  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end

  local data = jsonReadFile(currentSavePath .. SAVE_SUBDIR .. "/" .. SAVE_FILE) or {}
  ownersByGarageId = data.ownersByGarageId or {}
  npcRoster = data.npcRoster or {}
  ownershipTime = tonumber(data.ownershipTime) or latestOwnerActivityTime()
  updateAccumulator = 0
end

local function onOverhaulModulesActivated()
  loadOwners()
end

local function onExtensionLoaded()
  loadOwners()
end

-- Public API --------------------------------------------------------------------------------------

M.registerOwnerFromSale = registerOwnerFromSale
M.clearOwner = clearOwner
M.getOwner = getOwner
M.getOwnerForListing = getOwnerForListing
M.getSellerProfileForNegotiation = getSellerProfileForNegotiation

-- Game hooks --------------------------------------------------------------------------------------

M.onUpdate = onUpdate
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onOverhaulModulesActivated = onOverhaulModulesActivated
M.onExtensionLoaded = onExtensionLoaded

return M
