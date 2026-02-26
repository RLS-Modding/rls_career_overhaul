local M = {}
M.dependencies = { 'career_career', 'career_saveSystem' }

local saveFile = "propertyOwners.json"
local ownersByGarageId = {}
local npcRoster = {}
local updateAccumulator = 0
local UPDATE_INTERVAL_SECONDS = 120

local FIRST_NAMES = {
  "Alex", "Jordan", "Taylor", "Casey", "Morgan", "Avery", "Riley", "Cameron", "Parker", "Quinn",
  "Drew", "Skyler", "Reese", "Logan", "Sawyer", "Harper", "Blake", "Micah", "Emerson", "Rowan"
}

local LAST_INITIALS = { "A", "B", "C", "D", "E", "F", "G", "H", "J", "K", "L", "M", "N", "P", "R", "S", "T", "W" }

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

local function clamp(v, minV, maxV)
  if v < minV then return minV end
  if v > maxV then return maxV end
  return v
end

local function randomBetween(minV, maxV)
  return minV + (math.random() * (maxV - minV))
end

local function getCurrentTime()
  return os.time()
end

local function getHousingMarketIndex()
  if career_modules_globalEconomy and career_modules_globalEconomy.getHousingMarketIndex then
    return career_modules_globalEconomy.getHousingMarketIndex() or 1
  end
  return 1
end

local function getDurationBucket(purchaseTime)
  local ownedSeconds = math.max(0, getCurrentTime() - (purchaseTime or getCurrentTime()))
  if ownedSeconds < 300 then
    return "fresh", ownedSeconds
  elseif ownedSeconds < 3600 then
    return "moderate", ownedSeconds
  end
  return "long", ownedSeconds
end

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

local function generateOwnerName(archetype)
  local names = OWNER_GROUPS[archetype] or OWNER_GROUPS.investor
  if not names or #names == 0 then
    names = OWNER_GROUPS.investor
  end
  return names[math.random(1, #names)]
end

local function chooseArchetype()
  local keys = { "investor", "homeowner", "cash_strapped", "developer" }
  return keys[math.random(1, #keys)]
end

local function createNpcRecord(name, archetype)
  local a = ARCHETYPES[archetype] or ARCHETYPES.investor
  local npcId = string.format("npc_%d_%d", getCurrentTime(), math.random(1000, 9999))
  local record = {
    npcId = npcId,
    name = name or generateOwnerName(archetype),
    archetype = archetype,
    traits = {
      buyingTendency = randomBetween(0.4, 0.9),
      sellingTendency = randomBetween(0.35, 0.85),
      priceSensitivity = a.priceSensitivity,
      patienceProfile = randomBetween(a.patienceMin, a.patienceMax),
      adjustmentAggression = a.adjustmentAggression,
      adjustmentFrequencyMult = a.adjustmentFrequencyMult,
      emotionalAttachment = archetype == "homeowner" and randomBetween(0.6, 0.95) or randomBetween(0.15, 0.55),
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

  for npcId, record in pairs(npcRoster) do
    if record and record.name == name and record.archetype == archetype then
      return record
    end
  end

  return createNpcRecord(name, archetype)
end

local function calculateWillingness(ownerData)
  if not ownerData then return 0.5 end
  local archetypeData = ARCHETYPES[ownerData.archetype] or ARCHETYPES.investor
  local marketIndex = getHousingMarketIndex()
  local durationBucket = getDurationBucket(ownerData.purchaseTime)

  local willingness = archetypeData.baseWillingness

  if durationBucket == "fresh" then
    willingness = willingness - 0.45
  elseif durationBucket == "moderate" then
    willingness = willingness + 0.0
  else
    willingness = willingness + 0.2
  end

  if ownerData.archetype == "cash_strapped" and marketIndex < 0.95 then
    willingness = willingness + 0.2
  end

  if ownerData.archetype == "homeowner" and durationBucket == "fresh" then
    willingness = willingness - 0.2
  end

  if marketIndex < 0.85 then
    willingness = willingness - 0.05
  elseif marketIndex > 1.1 then
    willingness = willingness + 0.07
  end

  return clamp(willingness, 0.02, 0.98)
end

local function calculateAskingPrice(ownerData, basePrice)
  if not ownerData then return basePrice or 0 end
  local archetypeData = ARCHETYPES[ownerData.archetype] or ARCHETYPES.investor
  local marketIndex = getHousingMarketIndex()
  local purchasePrice = ownerData.purchasePrice or basePrice or 0
  local durationBucket = getDurationBucket(ownerData.purchaseTime)
  local baseMarkup = randomBetween(archetypeData.markupMin, archetypeData.markupMax)

  if durationBucket == "fresh" then
    baseMarkup = baseMarkup + 0.18
  elseif durationBucket == "long" then
    baseMarkup = baseMarkup - 0.05
  end

  if ownerData.archetype == "cash_strapped" and marketIndex < 0.9 and durationBucket == "long" then
    baseMarkup = baseMarkup - 0.12
  end

  local marketBias = (marketIndex - 1) * 0.5
  local ask = math.floor(math.max(1000, purchasePrice * (1 + baseMarkup + marketBias)) + 0.5)

  if ownerData.archetype == "developer" and marketIndex < 0.8 and ask < purchasePrice * 0.9 then
    ask = math.floor(purchasePrice * 0.95 + 0.5)
  end

  return math.max(1000, ask)
end

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
    willingnessToSell = 0.1,
    patienceProfile = npc.traits and npc.traits.patienceProfile or 0.5,
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

local function getOwnerForListing(garageId, fallbackPrice)
  local owner = ensureOwnerForGarage(garageId, fallbackPrice)
  if not owner then return nil end

  owner.willingnessToSell = calculateWillingness(owner)
  owner.currentAskingPrice = calculateAskingPrice(owner, fallbackPrice or owner.purchasePrice)

  return {
    garageId = garageId,
    name = owner.name,
    archetype = owner.archetype,
    currentAskingPrice = owner.currentAskingPrice,
    willingnessToSell = owner.willingnessToSell,
    purchasePrice = owner.purchasePrice,
    purchaseTime = owner.purchaseTime,
    patienceProfile = owner.patienceProfile,
    traits = owner.traits,
  }
end

local function buildFallbackSellerProfile(fallbackMarketPrice)
  local sellerType = DEFAULT_SELLER_TYPES[math.random(1, #DEFAULT_SELLER_TYPES)]
  local startingPrice = math.max(1000, math.floor((fallbackMarketPrice or 100000) * randomBetween(0.95, 1.15) + 0.5))
  return {
    source = "fallback",
    sellerType = sellerType,
    name = sellerType == "bank" and "Foreclosure Officer" or (sellerType == "developer" and "Regional Developer" or "Original Owner"),
    archetype = sellerType == "developer" and "developer" or "homeowner",
    startingPrice = startingPrice,
    willingnessToSell = sellerType == "bank" and 0.65 or 0.5,
    patience = sellerType == "bank" and 0.55 or 0.7,
    isPersistentOwner = false,
  }
end

local function getSellerProfileForNegotiation(garageId, fallbackMarketPrice)
  local owner = ensureOwnerForGarage(garageId, fallbackMarketPrice)
  if not owner then
    return buildFallbackSellerProfile(fallbackMarketPrice)
  end

  return {
    source = "owner",
    garageId = garageId,
    name = owner.name,
    archetype = owner.archetype,
    startingPrice = owner.currentAskingPrice,
    willingnessToSell = owner.willingnessToSell,
    patience = owner.patienceProfile,
    traits = owner.traits,
    isPersistentOwner = true,
  }
end

local function refreshOwner(ownerData)
  if not ownerData then return end
  local now = getCurrentTime()
  local archetypeData = ARCHETYPES[ownerData.archetype] or ARCHETYPES.investor
  local cadence = UPDATE_INTERVAL_SECONDS / math.max(0.25, archetypeData.adjustmentFrequencyMult or 1)

  if now - (ownerData.lastAdjustmentTime or 0) < cadence then return end

  ownerData.lastAdjustmentTime = now
  ownerData.willingnessToSell = calculateWillingness(ownerData)
  ownerData.currentAskingPrice = calculateAskingPrice(ownerData, ownerData.purchasePrice)
end

local function onUpdate(dtReal, dtSim)
  updateAccumulator = updateAccumulator + (dtReal or 0)
  if updateAccumulator < 5 then return end
  updateAccumulator = 0

  for _, ownerData in pairs(ownersByGarageId) do
    refreshOwner(ownerData)
  end
end

local function onSaveCurrentSaveSlot(currentSavePath)
  if not currentSavePath then
    local _, path = career_saveSystem.getCurrentSaveSlot()
    currentSavePath = path
    if not currentSavePath then return end
  end

  local dirPath = currentSavePath .. "/career/rls_career"
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end

  career_saveSystem.jsonWriteFileSafe(dirPath .. "/" .. saveFile, {
    ownersByGarageId = ownersByGarageId,
    npcRoster = npcRoster,
  }, true)
end

local function loadOwners()
  if not career_career.isActive() then return end

  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end

  local filePath = currentSavePath .. "/career/rls_career/" .. saveFile
  local data = jsonReadFile(filePath) or {}
  ownersByGarageId = data.ownersByGarageId or {}
  npcRoster = data.npcRoster or {}
end

local function onCareerModulesActivated()
  loadOwners()
end

local function onExtensionLoaded()
  loadOwners()
end

M.registerOwnerFromSale = registerOwnerFromSale
M.clearOwner = clearOwner
M.getOwner = getOwner
M.getOwnerForListing = getOwnerForListing
M.getSellerProfileForNegotiation = getSellerProfileForNegotiation
M.onUpdate = onUpdate
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onCareerModulesActivated = onCareerModulesActivated
M.onExtensionLoaded = onExtensionLoaded

return M
