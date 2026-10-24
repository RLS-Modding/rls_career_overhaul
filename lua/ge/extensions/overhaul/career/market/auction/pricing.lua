-- Stateless auction pricing: whole-dollar rounding, counter batch sizes and offer fees, and a lot's
-- condition-adjusted book value. Nothing here reads or writes auction state; callers pass the values.
local constants = require('overhaul/career/market/auction/constants')

local pricing = {}

function pricing.roundMoney(amount)
  return math.max(0, math.floor((tonumber(amount) or 0) + 0.5))
end

function pricing.roundToStep(value, step)
  local safeStep = math.max(1, tonumber(step) or 1)
  local normalized = math.max(0, tonumber(value) or 0) / safeStep
  return math.floor(normalized + 0.5) * safeStep
end

function pricing.clampLotBatchSize(value)
  local lotCount = math.floor(tonumber(value) or constants.DEFAULT_LOT_COUNT)
  if lotCount < constants.MIN_LOT_COUNT then
    lotCount = constants.MIN_LOT_COUNT
  end
  if lotCount > constants.MAX_LOT_COUNT then
    lotCount = constants.MAX_LOT_COUNT
  end
  return lotCount
end

-- Batches of up to the default size cost 75% to 100% of a full fee; larger batches cost up to 200%.
function pricing.lotBatchMultiplier(lotCount)
  local safeLots = pricing.clampLotBatchSize(lotCount)
  local baseLots = constants.DEFAULT_LOT_COUNT

  if safeLots <= baseLots then
    local lowSpan = math.max(1, baseLots - constants.MIN_LOT_COUNT)
    return 0.75 + ((safeLots - constants.MIN_LOT_COUNT) / lowSpan) * 0.25
  end

  local highSpan = math.max(1, constants.MAX_LOT_COUNT - baseLots)
  return 1 + ((safeLots - baseLots) / highSpan)
end

-- Registration price after the entry credit is spent. Returns nil for a missing offer.
function pricing.counterOfferPricing(offer, lotCount, creditRemainingRaw)
  if type(offer) ~= 'table' then
    return nil
  end

  local safeLotCount = pricing.clampLotBatchSize(lotCount)
  local rawCost = pricing.roundMoney((tonumber(offer.fullFee) or 0) * pricing.lotBatchMultiplier(safeLotCount))
  local creditRemaining = pricing.roundMoney(creditRemainingRaw or 0)
  local creditApplied = math.min(rawCost, creditRemaining)
  local registrationFee = math.max(0, rawCost - creditApplied)

  return {
    lotCount = safeLotCount,
    rawCost = rawCost,
    creditApplied = creditApplied,
    registrationFee = registrationFee,
    remainingCreditAfter = math.max(0, creditRemaining - creditApplied)
  }
end

function pricing.findCounterOffer(offers, typeId)
  if type(typeId) ~= 'string' or typeId == '' then
    return nil
  end

  for _, offer in ipairs(offers or {}) do
    if offer.id == typeId then
      return offer
    end
  end
  return nil
end

function pricing.lotMileageMeters(lot)
  local mileageMiles = tonumber(lot and lot.mileage) or 0
  return math.max(0, math.floor(mileageMiles * constants.METERS_PER_MILE))
end

function pricing.currentYear()
  return tonumber(os.date('%Y')) or 2025
end

-- The configuration key is the file name under configurations/ (or the bare file name).
function pricing.configKeyFromPath(configPath)
  if type(configPath) ~= 'string' then return nil end
  local normalized = configPath:gsub('\\', '/')
  local key = normalized:match('/configurations/([^/]+)%.pc$')
  if key then
    return key
  end
  return normalized:match('/([^/]+)%.pc$')
end

-- Book value of a lot's model, configuration, age and mileage. Nil when the lot has no base value.
function pricing.conditionedLotBasePrice(lot)
  if not lot then
    return nil
  end

  local baseValue = tonumber(lot.basePrice) or tonumber(lot.currentBid) or 0
  if baseValue <= 0 then
    return nil
  end

  local mileageMeters = pricing.lotMileageMeters(lot)
  local vehicleYear = tonumber(lot.year) or pricing.currentYear()
  local vehicleAge = math.max(0, pricing.currentYear() - vehicleYear)

  return overhaul_career_market_valueCalculator.getVehicleCatalogIntrinsicBookValue({
    catalogBaseValue = baseValue,
    mileageMeters = mileageMeters,
    age = vehicleAge,
    modelName = lot.model,
    configKey = pricing.configKeyFromPath(lot.config),
    logContext = 'usedCarAuction',
    applyVehicleBuyMarket = true
  })
end

return pricing
