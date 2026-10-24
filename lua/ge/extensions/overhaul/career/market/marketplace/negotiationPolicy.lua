-- Negotiation price policy: patience, reply timing and counter-offers without session state.
-- The owner applies these results after its token checks; random draws retain their call order.
local policy = {}

local tuning = {
  priceStep = 50,
  percentScale = 100,
  percentagePriceScale = 1000,
  absoluteGapScale = 100,
  dealerPatienceMultiplier = 0.6,
  nearMarketFraction = 0.9,
  privateNearMarketGapMultiplier = 0.5,
  selling = {percentageDrop = 3, absoluteDrop = 8, randomDrop = 12},
  buying = {percentageDrop = 2.5, absoluteDrop = 6, randomDrop = 10},
  privateCounter = {baseFraction = 0.3, randomFraction = 0.4},
  hiddenOpeningCounter = {baseFraction = 0.08, randomFraction = 0.12},
  dealerCounter = {
    impatienceFraction = 0.4, baseFraction = 0.25,
    randomFraction = 0.15, randomOffset = 0.075,
    minFraction = 0.15, maxFraction = 0.75,
  },
  overBudgetCounter = {
    baseMultiplier = 0.5, randomFraction = 0.1, randomOffset = 0.05,
    minFraction = 0.10, maxFraction = 0.50,
  },
  dealerFloor = {minimumOverMarket = 200, desperationDiscountFraction = 0.35},
  dealerPatienceFraction = 0.8,
  lowPatienceFraction = 0.40,
  sellingMaximumMultiplier = 1.05,
  timing = {
    marketGapFraction = 0.15, askingGapFraction = 0.20,
    largeAskingGapFraction = 0.30, smallMarketGapFraction = 0.10,
    nearMarketFarAsking = {baseS = 2.5, randomS = 1.5},
    farAsking = {baseS = 1.0, randomS = 0.8},
    nearMarket = {baseS = 2.0, randomS = 1.0},
    dealerDefault = {baseS = 1.5, randomS = 1.0},
    privateDefault = {baseS = 2.0, randomS = 2.0},
    exhaustedS = 0.5, durationDivisor = 2, minimumS = 1,
  },
}

-- Clamp after rounding so an unrounded dealer floor and buyer budget keep their existing limits.
local function roundToNearest(value, step)
  return math.floor(value / step + 0.5) * step
end

local function blendedPatienceDrop(referenceGap, referenceValue, isDealership, rates, minRatioDenominator)
  local priceScaleValue = math.max(tonumber(referenceValue) or 0, minRatioDenominator)
  local gapPercent = (referenceGap / priceScaleValue) * tuning.percentScale
  local priceScale = math.min(1, priceScaleValue / tuning.percentagePriceScale)
  local percentageWeight = priceScale
  local absoluteWeight = 1 - priceScale
  local percentageDrop = gapPercent * rates.percentageDrop
  local absoluteDrop = (referenceGap / tuning.absoluteGapScale) * rates.absoluteDrop
  local dealerMultiplier = isDealership and tuning.dealerPatienceMultiplier or 1.0
  local drop = ((percentageDrop * percentageWeight + absoluteDrop * absoluteWeight) * dealerMultiplier)
    + math.random() * rates.randomDrop
  return drop / tuning.percentScale
end

local function dealerMovementFraction(patience, overBudget)
  local counter = tuning.dealerCounter
  local baseFraction = (1 - patience) * counter.impatienceFraction + counter.baseFraction
  local variation = counter
  if overBudget then
    variation = tuning.overBudgetCounter
    baseFraction = baseFraction * variation.baseMultiplier
  end
  local fraction = baseFraction + (math.random() * variation.randomFraction - variation.randomOffset)
  return math.max(variation.minFraction, math.min(variation.maxFraction, fraction))
end

function policy.sellingPatienceDrop(myOffer, theirOffer, baseValue, isDealership, minRatioDenominator)
  local buyerOffer = theirOffer or baseValue
  local gapFromBuyer = math.abs(myOffer - buyerOffer)
  local gapFromMarket = math.abs(myOffer - baseValue)
  local referenceGap = isDealership and gapFromBuyer or gapFromMarket
  local referenceValue = isDealership and buyerOffer or baseValue
  return blendedPatienceDrop(referenceGap, referenceValue, isDealership, tuning.selling, minRatioDenominator)
end

function policy.buyingPatienceDrop(myOffer, theirOffer, baseValue, startingPrice, insultThreshold, isDealership, minRatioDenominator)
  if (tonumber(myOffer) or 0) >= (tonumber(baseValue) or 0) then return 0 end
  local askingPrice = theirOffer or baseValue
  local gapFromAsking = math.abs(myOffer - askingPrice)
  local gapFromMarket = math.abs(myOffer - baseValue)
  local referenceGap, referenceValue
  if isDealership then
    local marketBase = tonumber(baseValue) or 0
    local floorOffer = marketBase > 0 and marketBase * tuning.nearMarketFraction or startingPrice * insultThreshold
    local minimumOffer = math.min(startingPrice * insultThreshold, floorOffer)
    if myOffer < minimumOffer then return 1, true end
    referenceGap = gapFromAsking
    referenceValue = askingPrice
  else
    local marketBase = tonumber(baseValue) or 0
    if marketBase > 0 and myOffer >= marketBase * tuning.nearMarketFraction then
      referenceGap = gapFromAsking * tuning.privateNearMarketGapMultiplier
      referenceValue = askingPrice
    else
      referenceGap = gapFromMarket
      referenceValue = math.max(marketBase, minRatioDenominator)
    end
  end
  return blendedPatienceDrop(referenceGap, referenceValue, isDealership, tuning.buying, minRatioDenominator)
end

function policy.thinkingTimeS(myOffer, startingPrice, baseValue, patience, isDealership, minRatioDenominator)
  local timing = tuning.timing
  local range = timing.privateDefault
  if isDealership then
    local marketGap = math.abs(myOffer - baseValue) / math.max(baseValue, minRatioDenominator)
    local askingGap = math.abs(myOffer - startingPrice) / math.max(tonumber(startingPrice) or 0, minRatioDenominator)
    if marketGap < timing.marketGapFraction and askingGap > timing.askingGapFraction then
      range = timing.nearMarketFarAsking
    elseif askingGap > timing.largeAskingGapFraction then
      range = timing.farAsking
    elseif marketGap < timing.smallMarketGapFraction then
      range = timing.nearMarket
    else
      range = timing.dealerDefault
    end
  end
  local durationS = range.baseS + math.random() * range.randomS
  if patience <= 0 then durationS = timing.exhaustedS end
  return durationS / timing.durationDivisor + timing.minimumS
end

function policy.privateCounterOffer(myOffer, theirOffer, amISelling, hiddenOpeningOffer, maxBuyerPrice)
  local difference = theirOffer - myOffer
  local range = tuning.privateCounter
  local weight = range.baseFraction + math.random() * range.randomFraction
  if not amISelling and hiddenOpeningOffer then
    range = tuning.hiddenOpeningCounter
    weight = range.baseFraction + math.random() * range.randomFraction
  end
  local movement = math.abs(difference) * weight
  if amISelling then
    local result = theirOffer + movement
    local step = math.max(theirOffer, roundToNearest(result, tuning.priceStep))
    return math.min(step, maxBuyerPrice)
  end
  local result = theirOffer - movement
  return math.max(myOffer, roundToNearest(result, tuning.priceStep))
end

function policy.dealerMinimumPrice(startingPrice, baseValue, patience, isDesperate, personality)
  local minimumOverMarket = personality.minimumOverMarket or tuning.dealerFloor.minimumOverMarket
  local discountFraction = personality.desperationMaxDiscount or tuning.dealerFloor.desperationDiscountFraction
  local absoluteMinimum = isDesperate and baseValue * (1 - discountFraction) or baseValue + minimumOverMarket
  local negotiationRange = startingPrice - absoluteMinimum
  local patienceMultiplier = patience * tuning.dealerPatienceFraction
  local willingToNegotiate = negotiationRange * patienceMultiplier
  return startingPrice - willingToNegotiate
end

function policy.dealerBuyingCounter(myOffer, theirOffer, minimumPrice, patience)
  if patience <= tuning.lowPatienceFraction then
    return roundToNearest(minimumPrice, tuning.priceStep)
  end
  local gapToClose = theirOffer - myOffer
  if myOffer >= minimumPrice then
    if gapToClose <= 0 then return myOffer end
    local counterAmount = myOffer + (gapToClose * dealerMovementFraction(patience, false))
    return math.min(math.max(myOffer, roundToNearest(counterAmount, tuning.priceStep)), theirOffer)
  end
  local counterAmount = myOffer + (gapToClose * dealerMovementFraction(patience, false))
  return math.max(minimumPrice, roundToNearest(counterAmount, tuning.priceStep))
end

function policy.dealerSellingCounter(myOffer, theirOffer, startingPrice, patience, maxBuyerPrice)
  local maximumPrice = math.min(startingPrice * tuning.sellingMaximumMultiplier, maxBuyerPrice)
  local candidate
  if patience <= tuning.lowPatienceFraction then
    candidate = roundToNearest(maximumPrice, tuning.priceStep)
  elseif myOffer <= maximumPrice then
    local gapToClose = myOffer - theirOffer
    local counterAmount = theirOffer + (gapToClose * dealerMovementFraction(patience, false))
    candidate = math.min(myOffer, roundToNearest(counterAmount, tuning.priceStep), maxBuyerPrice)
  else
    local gapToClose = myOffer - theirOffer
    local counterAmount = theirOffer + (gapToClose * dealerMovementFraction(patience, true))
    candidate = math.min(maximumPrice, roundToNearest(counterAmount, tuning.priceStep), maxBuyerPrice)
  end
  return math.max(candidate, theirOffer)
end

return policy
