-- Global economy: a slow boom-and-bust index with housing, job and vehicle sub-markets, random events, news and history.
-- Map: config and state, phase and market steps, events, persistence, price readers, tick and lifecycle.
local M = {}

local saveStore = require("overhaul/lib/save/store")
local ensureDir = require("overhaul/lib/save/ensureDir")

-- Config ---------------------------------------------------------------------------------------------

local SIM_SECONDS_PER_GAME_DAY = require("overhaul/lib/career/gameTime").SIM_SECONDS_PER_GAME_DAY
local UPDATE_INTERVAL_SIM = 300 -- sim-seconds between economy ticks
local MIN_INDEX = 0.5
local MAX_INDEX = math.huge


-- Phase duration ranges in sim-seconds.
local PHASE_DURATIONS = {
  growth  = { 10 * SIM_SECONDS_PER_GAME_DAY, 25 * SIM_SECONDS_PER_GAME_DAY },
  peak    = {  5 * SIM_SECONDS_PER_GAME_DAY, 12 * SIM_SECONDS_PER_GAME_DAY },
  decline = {  8 * SIM_SECONDS_PER_GAME_DAY, 20 * SIM_SECONDS_PER_GAME_DAY },
  trough  = {  5 * SIM_SECONDS_PER_GAME_DAY, 15 * SIM_SECONDS_PER_GAME_DAY },
}
local PHASE_ORDER = { "growth", "peak", "decline", "trough" }

local PHASE_MOMENTUM = {
  growth  =  0.003,
  peak    =  0.0,
  decline = -0.003,
  trough  =  0.0,
}

local GLOBAL_MOMENTUM_NOISE = 0.0022
local GLOBAL_MOMENTUM_NOISE_BURST_PROB = 0.16
local GLOBAL_MOMENTUM_NOISE_BURST_MULT = 4.5
local IMPULSE_PROB_PER_TICK = 0.09
local IMPULSE_LARGE_MOVE_PROB = 0.30
local IMPULSE_GLOBAL_MIN = 0.02
local IMPULSE_GLOBAL_MAX = 0.065
local IMPULSE_MOMENTUM_DAMP = 0.50
local SUB_MARKET_IMPULSE_PROB = 0.05
local SUB_MARKET_IMPULSE_LARGE_MOVE_PROB = 0.25
local SUB_MARKET_IMPULSE_MIN = 0.012
local SUB_MARKET_IMPULSE_MAX = 0.04

-- Pulls the global index back toward 1.0 each tick, on top of momentum reversion.
local GLOBAL_INDEX_ANCHOR_PULL = 0.26

local SUB_MARKET_KEYS = { "housingMarket", "jobMarket", "vehicleMarket" }
local SUB_MARKET_DEFAULTS = {
  housingMarket = { sensitivity = 0.7, lagDays = 5,  noiseRange = 0.032, impulseScale = 0.85 },
  jobMarket     = { sensitivity = 1.3, lagDays = -2, noiseRange = 0.05, impulseScale = 1.15 },
  vehicleMarket = { sensitivity = 0.8, lagDays = 3,  noiseRange = 0.034, impulseScale = 1.0 },
}

local cycleTuning = {
  peakDampingPerGameDay = 0.12,
  troughDampingPerGameDay = 0.10,
  overheatedIndex = 1.2,
  rolloverPressurePerGameDay = 0.0008,
  overheatedPressureScale = 0.0012,
  settledMomentumThreshold = 0.0002,
  growthDeviationCap = 1.5,
  growthMomentumScale = 0.7,
  declineDeviationCap = 2.0,
  declineMomentumScale = 0.0025,
  momentumBlendFraction = 0.05,
  minimumTurnaroundPhaseFraction = 0.3,
  reversionBase = 0.0022,
  reversionDeviationCap = 2.0,
  reversionDeviationScale = 0.0028,
}

local MAX_HISTORY = 10
local MAX_ARTICLES = 20

-- News and event config ------------------------------------------------------------------------------

local PHASE_TRANSITION_ARTICLES = {
  growth = {
    { headline = "Economy Showing Signs of Recovery", body = "Market conditions are improving across the board. Businesses are cautiously optimistic as spending picks up.", sector = "global" },
    { headline = "Growth Returns to Local Economy", body = "After a period of stagnation, economic activity is picking up again. Expect gradual improvements in wages and job availability.", sector = "global" },
  },
  peak = {
    { headline = "Economy Reaches New Heights", body = "The local economy is booming. Jobs are plentiful, businesses are thriving, and consumer confidence is at an all-time high.", sector = "global" },
    { headline = "Markets Hit Peak Performance", body = "Economic indicators suggest we're at the top of the cycle. Enjoy the good times while they last.", sector = "global" },
  },
  decline = {
    { headline = "Economic Outlook Turns Cautious", body = "Growth is slowing as the economy enters a cooling period. Some businesses may tighten their belts in the coming weeks.", sector = "global" },
    { headline = "Markets Begin to Cool Off", body = "After a strong run, the economy is showing signs of slowing down. Prices may become more favorable for buyers.", sector = "global" },
  },
  trough = {
    { headline = "Economy Hits a Rough Patch", body = "Times are tough. Jobs are harder to find and pay rates have dropped. Budget carefully until conditions improve.", sector = "global" },
    { headline = "Economic Downturn Deepens", body = "The economy continues to struggle. Look for bargains on vehicles and property while prices are low.", sector = "global" },
  },
}

local BOOM_ARTICLES = {
  { headline = "Job Market on Fire", body = "Employers are hiring again as economic conditions improve. Expect better pay for delivery and transport work.", sector = "jobs" },
  { headline = "Property Values Soar", body = "A strong economy has driven housing prices to new highs. Homeowners are sitting pretty, but buyers may want to wait.", sector = "housing" },
  { headline = "Vehicle Demand Surges", body = "A hot economy means car prices are climbing. If you're looking to sell, now's the time.", sector = "vehicles" },
  { headline = "Fuel Costs Surge", body = "Rising demand and economic growth have pushed fuel prices higher across all stations.", sector = "global" },
}

local RECESSION_ARTICLES = {
  { headline = "Job Market Shows Signs of Strain", body = "Fewer jobs are available and wages are down. Consider diversifying your income sources.", sector = "jobs" },
  { headline = "Property Prices Drop", body = "A weak economy has pushed housing prices down. It might be a good time to invest in real estate.", sector = "housing" },
  { headline = "Vehicle Prices Plummet", body = "A sluggish economy has driven car prices to new lows. Now might be the time to buy.", sector = "vehicles" },
  { headline = "Fuel Prices Ease", body = "Reduced economic activity has brought fuel costs down. Enjoy cheaper fill-ups while they last.", sector = "global" },
}

local EVENT_ARTICLES = {
  economic_stimulus  = { headline = "Government Announces Economic Stimulus", body = "New stimulus measures are expected to boost spending and help local businesses recover.", sector = "global" },
  recession_warning  = { headline = "Economists Issue Recession Warning", body = "Analysts are concerned about a potential downturn. Consider saving more and spending less.", sector = "global" },
  trade_deal         = { headline = "New Trade Agreement Signed", body = "A new trade deal promises to bring more business opportunities and lower costs for consumers.", sector = "global" },
  market_panic       = { headline = "Markets in Turmoil", body = "Sudden market volatility has investors worried. Hold steady and avoid panic selling.", sector = "global" },
  tech_boom          = { headline = "Tech Sector Drives Growth", body = "A surge in technology spending is lifting the entire economy. Good times ahead for workers.", sector = "global" },
  consumer_confidence = { headline = "Shoppers Open Their Wallets Again", body = "A burst of consumer confidence is lifting local businesses and pushing the economy higher.", sector = "global" },
  credit_crunch      = { headline = "Lenders Tighten the Screws", body = "Credit is getting harder to find, cooling spending and putting fresh pressure on the broader economy.", sector = "global" },
  hiring_boom        = { headline = "Hiring Spree Underway", body = "Companies are adding staff at a rapid pace. Now is a great time to look for better-paying work.", sector = "jobs" },
  layoff_wave        = { headline = "Layoffs Sweep Through Businesses", body = "Several employers have announced cutbacks. Job seekers may face stiff competition for a while.", sector = "jobs" },
  gig_surge          = { headline = "Gig Work Demand Explodes", body = "Delivery and freelance jobs are booming. Independent drivers can expect more work and better tips.", sector = "jobs" },
  fuel_spike         = { headline = "Fuel Prices Jump Sharply", body = "A sudden spike in fuel costs is hitting drivers hard. Plan your routes carefully to save money.", sector = "jobs" },
  racing_season      = { headline = "Racing Season Kicks Off", body = "Motorsport fever is driving demand for performance parts and skilled drivers. Exciting times on the track!", sector = "jobs" },
  new_model_year     = { headline = "New Vehicle Models Hit the Market", body = "Fresh inventory means dealers are clearing out last year's stock at steep discounts.", sector = "vehicles" },
  parts_shortage     = { headline = "Auto Parts in Short Supply", body = "A shortage of key components has driven up repair and modification costs across the board.", sector = "vehicles" },
  insurance_hike     = { headline = "Insurance Rates Climb", body = "Higher premiums are making vehicle ownership more expensive. Shop around for better coverage.", sector = "vehicles" },
  car_show           = { headline = "Big Car Show Coming to Town", body = "Auto enthusiasts are flocking to the area. Expect increased interest in buying and selling vehicles.", sector = "vehicles" },
  fleet_sale         = { headline = "Fleet Vehicles Going Cheap", body = "A major fleet operator is liquidating vehicles at rock-bottom prices. Great deals for budget buyers.", sector = "vehicles" },
  road_construction  = { headline = "Road Construction Disrupts Area", body = "Major roadwork is causing headaches for commuters and temporarily hurting nearby property values.", sector = "housing" },
  new_business_opens = { headline = "New Businesses Open Nearby", body = "Several new shops and services are opening in the area, boosting property appeal.", sector = "housing" },
  crime_wave         = { headline = "Rise in Local Crime Reported", body = "A recent uptick in crime is making some neighborhoods less desirable. Stay alert out there.", sector = "housing" },
  housing_boom       = { headline = "Housing Market Heats Up", body = "Strong demand and limited supply are pushing property prices higher. Sellers are in the driver's seat.", sector = "housing" },
  market_correction  = { headline = "Housing Market Corrects", body = "Overheated property prices are coming back to earth. Buyers may find better deals soon.", sector = "housing" },
  zoning_change      = { headline = "Zoning Changes Approved", body = "New zoning regulations are opening up areas for development, potentially increasing property values.", sector = "housing" },
}


local STARTING_HEADLINES = {
  booming = "State of the Economy: Boom Times",
  healthy = "State of the Economy: Looking Good",
  stable = "State of the Economy: Steady as She Goes",
  sluggish = "State of the Economy: Slow Going",
  struggling = "State of the Economy: Tough Times Ahead",
}

local STARTING_BODIES = {
  booming = "Welcome! The economy is running hot right now. Jobs pay well, but expect higher prices on vehicles and property. A good time to earn and save.",
  healthy = "Welcome! Economic conditions are favorable. Jobs are available, prices are fair, and there are opportunities for those willing to work hard.",
  stable = "Welcome! The economy is in a neutral state — nothing spectacular, but nothing to worry about either. A balanced time to start building your career.",
  sluggish = "Welcome! The economy is a bit slow right now. Jobs may pay less, but you'll find better deals on vehicles and property. Every cloud has a silver lining.",
  struggling = "Welcome! Times are tough out there. Work pays less and jobs are scarce, but vehicle and property prices are rock bottom. Buy low, sell high later.",
}


local GLOBAL_EVENTS = {
  { id = "economic_stimulus",  modifier =  0.008, durationDaysMin = 10, durationDaysMax = 20, probability = 0.045 },
  { id = "recession_warning",  modifier = -0.006, durationDaysMin = 5,  durationDaysMax = 15, probability = 0.05 },
  { id = "trade_deal",         modifier =  0.004, durationDaysMin = 7,  durationDaysMax = 12, probability = 0.045 },
  { id = "market_panic",       modifier = -0.012, durationDaysMin = 3,  durationDaysMax = 5,  probability = 0.03 },
  { id = "tech_boom",          modifier =  0.010, durationDaysMin = 10, durationDaysMax = 20, probability = 0.03 },
  { id = "consumer_confidence", modifier =  0.006, durationDaysMin = 3,  durationDaysMax = 7,  probability = 0.03 },
  { id = "credit_crunch",      modifier = -0.009, durationDaysMin = 3,  durationDaysMax = 6,  probability = 0.025 },
}

local JOB_EVENTS = {
  { id = "hiring_boom",       modifier =  0.15, durationDaysMin = 5,  durationDaysMax = 10, probability = 0.04 },
  { id = "layoff_wave",       modifier = -0.12, durationDaysMin = 3,  durationDaysMax = 8,  probability = 0.04 },
  { id = "gig_surge",         modifier =  0.08, durationDaysMin = 5,  durationDaysMax = 12, probability = 0.03 },
  { id = "fuel_spike",        modifier = -0.05, durationDaysMin = 3,  durationDaysMax = 6,  probability = 0.03 },
  { id = "racing_season",     modifier =  0.20, durationDaysMin = 7,  durationDaysMax = 14, probability = 0.02 },
}

local VEHICLE_EVENTS = {
  { id = "new_model_year",    modifier = -0.08, durationDaysMin = 5,  durationDaysMax = 10, probability = 0.03 },
  { id = "parts_shortage",    modifier =  0.10, durationDaysMin = 7,  durationDaysMax = 14, probability = 0.03 },
  { id = "insurance_hike",    modifier = -0.05, durationDaysMin = 5,  durationDaysMax = 8,  probability = 0.03 },
  { id = "car_show",          modifier =  0.12, durationDaysMin = 3,  durationDaysMax = 5,  probability = 0.04 },
  { id = "fleet_sale",        modifier = -0.15, durationDaysMin = 2,  durationDaysMax = 4,  probability = 0.02 },
}

local HOUSING_EVENTS = {
  { id = "road_construction",  modifier = -0.05, durationDaysMin = 5,  durationDaysMax = 10, probability = 0.04 },
  { id = "new_business_opens", modifier =  0.05, durationDaysMin = 10, durationDaysMax = 20, probability = 0.03 },
  { id = "crime_wave",         modifier = -0.08, durationDaysMin = 3,  durationDaysMax = 7,  probability = 0.03 },
  { id = "housing_boom",       modifier =  0.10, durationDaysMin = 5,  durationDaysMax = 15, probability = 0.02 },
  { id = "market_correction",  modifier = -0.10, durationDaysMin = 1,  durationDaysMax = 3,  probability = 0.02 },
  { id = "zoning_change",      modifier =  0.08, durationDaysMin = 7,  durationDaysMax = 14, probability = 0.03 },
}

-- Each definition rolls once per tick unless an event with its id is already running.
-- State ----------------------------------------------------------------------------------------------

local savePathFeature = nil

local economyData = nil
local accumulatedSimTime = 0
local timeSinceLastUpdate = 0
-- Index snapshot taken before each tick, for detecting threshold crossings.
local previousIndices = nil

-- Math helpers ---------------------------------------------------------------------------------------

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function randomInRange(lo, hi) return lo + math.random() * (hi - lo) end

-- Large moves land in the upper part of the range with probability largeMoveProbability.
local function randomShockMagnitude(minValue, maxValue, largeMoveProbability)
  local spread = maxValue - minValue
  if spread <= 0 then return minValue end
  if math.random() < (largeMoveProbability or 0) then
    return randomInRange(minValue + spread * 0.45, maxValue)
  end
  return randomInRange(minValue, minValue + spread * 0.55)
end

-- Shocks lean back toward 1.0: below normal favors an upward move, above normal a downward one.
local function getCounterTrendImpulseDirection(index)
  local deviation = (index or 1.0) - 1.0
  local upChance = 0.5
  if deviation <= -0.15 then
    upChance = 0.80
  elseif deviation <= -0.05 then
    upChance = 0.68
  elseif deviation >= 0.15 then
    upChance = 0.20
  elseif deviation >= 0.05 then
    upChance = 0.32
  end
  return math.random() < upChance and 1 or -1
end

local function randomPhaseDuration(phase)
  local range = PHASE_DURATIONS[phase]
  return randomInRange(range[1], range[2])
end

local function nextPhase(phase)
  for i, name in ipairs(PHASE_ORDER) do
    if name == phase then return PHASE_ORDER[(i % #PHASE_ORDER) + 1] end
  end
  return "growth"
end

-- Active events --------------------------------------------------------------------------------------

-- Drops expired events and sums the modifier of the rest.
local function getActiveEventModifier(events, fieldName)
  local modifier = 0
  if not events then return modifier end
  for i = #events, 1, -1 do
    local event = events[i]
    if accumulatedSimTime > (event.startTime or 0) + (event.durationSim or 0) then
      table.remove(events, i)
    else
      modifier = modifier + (event[fieldName or "modifier"] or 0)
    end
  end
  return modifier
end

local function addEvent(targetEvents, event)
  event.startTime = event.startTime or accumulatedSimTime
  table.insert(targetEvents, event)
end

local function hasActiveEvent(events, eventId)
  for _, event in ipairs(events or {}) do
    if event.id == eventId then return true end
  end
  return false
end

-- News articles --------------------------------------------------------------------------------------

local function addArticle(headline, body, sector)
  if not economyData then return end
  if not economyData.articles then economyData.articles = {} end
  table.insert(economyData.articles, {
    timestamp = accumulatedSimTime,
    headline = headline,
    body = body,
    sector = sector or "global",
  })
  while #economyData.articles > MAX_ARTICLES do
    table.remove(economyData.articles, 1)
  end
end

local function generatePhaseTransitionArticle(newPhase)
  local pool = PHASE_TRANSITION_ARTICLES[newPhase]
  if not pool then return end
  local article = pool[math.random(#pool)]
  addArticle(article.headline, article.body, article.sector)
end

-- Boom above 1.2 and recession below 0.8, only on the tick that crosses the line.
local function generateThresholdArticles()
  if not economyData then return end
  if economyData.index > 1.2 and previousIndices and previousIndices.global <= 1.2 then
    local article = BOOM_ARTICLES[math.random(#BOOM_ARTICLES)]
    addArticle(article.headline, article.body, article.sector)
  end
  if economyData.index < 0.8 and previousIndices and previousIndices.global >= 0.8 then
    local article = RECESSION_ARTICLES[math.random(#RECESSION_ARTICLES)]
    addArticle(article.headline, article.body, article.sector)
  end
end

local function generateEventArticle(eventId)
  local article = EVENT_ARTICLES[eventId]
  if article then
    addArticle(article.headline, article.body, article.sector)
  end
end

local function generateImpulseArticle(delta)
  local magnitude = math.abs(delta or 0)
  if magnitude <= 0 then return end

  local positive = (delta or 0) > 0
  local calmPool = positive and {
    { headline = "Market Sentiment Turns Up", body = "A quick burst of optimism has pushed the economy higher, giving buyers and workers a little breathing room." },
    { headline = "Unexpected Rally Lifts Economy", body = "A sharp move higher has broken the recent pattern, though traders expect things to settle back down soon." },
  } or {
    { headline = "Sudden Selloff Shakes Economy", body = "A quick wave of caution has dragged the economy lower, reminding everyone how fast conditions can change." },
    { headline = "Confidence Slips in a Hurry", body = "The market took a sudden step down today, cooling prices and pay expectations across the board." },
  }
  local bigMovePool = positive and {
    { headline = "Economic Rebound Surprises Analysts", body = "The economy just posted a sharp upside move, snapping back harder than most observers expected." },
    { headline = "Buying Frenzy Sparks Broad Rally", body = "A strong jump in activity has sent the economy surging higher in short order." },
  } or {
    { headline = "Market Reversal Hits Hard", body = "A fast downside move just cut into recent gains, leaving businesses and shoppers on edge." },
    { headline = "Sharp Downturn Jolts Local Economy", body = "Conditions shifted quickly today as a heavy selloff pushed the economy lower." },
  }
  local pool = magnitude >= 0.045 and bigMovePool or calmPool
  local article = pool[math.random(#pool)]
  addArticle(article.headline, article.body, "global")
end

local function generateStartingArticle()
  if not economyData then return end
  local index = economyData.index
  local condition
  if index > 1.2 then condition = "booming"
  elseif index > 1.05 then condition = "healthy"
  elseif index > 0.95 then condition = "stable"
  elseif index > 0.8 then condition = "sluggish"
  else condition = "struggling" end

  addArticle(STARTING_HEADLINES[condition], STARTING_BODIES[condition], "global")
end

-- Random events --------------------------------------------------------------------------------------

local function rollEvents(targetEvents, eventDefs)
  for _, def in ipairs(eventDefs) do
    if not hasActiveEvent(targetEvents, def.id) and math.random() < def.probability then
      local durationDays = randomInRange(def.durationDaysMin, def.durationDaysMax)
      addEvent(targetEvents, {
        id = def.id,
        modifier = def.modifier,
        durationSim = durationDays * SIM_SECONDS_PER_GAME_DAY,
      })
      generateEventArticle(def.id)
    end
  end
end

-- Global index ---------------------------------------------------------------------------------------

-- Momentum for the current phase. Growth and decline lean against an index above 1.0, and peak and trough cool down. Draws noise, so the call order matters for replays.
local function updatePhaseMomentum(economy, deviation, cycleDays)
  if economy.cyclePhase == "peak" then
    economy.momentum = economy.momentum * (1 - cycleTuning.peakDampingPerGameDay * cycleDays)
    -- Force rollover pressure when overheated so booms can actually break.
    if economy.index > cycleTuning.overheatedIndex then
      economy.momentum = economy.momentum - (cycleTuning.rolloverPressurePerGameDay + (economy.index - cycleTuning.overheatedIndex) * cycleTuning.overheatedPressureScale) * cycleDays
    end
    if math.abs(economy.momentum) < cycleTuning.settledMomentumThreshold then economy.momentum = 0 end
  elseif economy.cyclePhase == "trough" then
    economy.momentum = economy.momentum * (1 - cycleTuning.troughDampingPerGameDay * cycleDays)
    if math.abs(economy.momentum) < cycleTuning.settledMomentumThreshold then economy.momentum = 0 end
  else
    local baseMomentum = PHASE_MOMENTUM[economy.cyclePhase] or 0
    if economy.cyclePhase == "growth" and deviation > 0 then
      baseMomentum = baseMomentum * (1 - math.min(deviation, cycleTuning.growthDeviationCap) * cycleTuning.growthMomentumScale)
    elseif economy.cyclePhase == "decline" and deviation > 0 then
      baseMomentum = baseMomentum - math.min(deviation, cycleTuning.declineDeviationCap) * cycleTuning.declineMomentumScale
    end
    local noise = (math.random() - 0.5) * GLOBAL_MOMENTUM_NOISE
    if math.random() < GLOBAL_MOMENTUM_NOISE_BURST_PROB then
      noise = noise * GLOBAL_MOMENTUM_NOISE_BURST_MULT
    end
    economy.momentum = economy.momentum + (baseMomentum - economy.momentum) * cycleTuning.momentumBlendFraction + noise
  end
end

-- Moves to the next phase once the current one has run its course, or has turned around early.
local function advancePhaseIfDue(economy)
  if economy.phaseProgress >= 1.0 or
     (economy.cyclePhase == "peak" and economy.momentum <= 0 and economy.phaseProgress > cycleTuning.minimumTurnaroundPhaseFraction) or
     (economy.cyclePhase == "trough" and economy.momentum >= 0 and economy.phaseProgress > cycleTuning.minimumTurnaroundPhaseFraction) then
    economy.cyclePhase = nextPhase(economy.cyclePhase)
    economy.phaseProgress = 0
    economy.phaseDuration = randomPhaseDuration(economy.cyclePhase)
    economy.momentum = PHASE_MOMENTUM[economy.cyclePhase]
  end
end

local function updateGlobalIndex(dtSim)
  local economy = economyData
  if not economy then return end
  local cycleDays = dtSim / SIM_SECONDS_PER_GAME_DAY
  local deviation = economy.index - 1.0
  local absDeviation = math.abs(deviation)

  economy.phaseProgress = economy.phaseProgress + (dtSim / economy.phaseDuration)

  updatePhaseMomentum(economy, deviation, cycleDays)

  -- Mean reversion on momentum: stronger when the economy is far from normal.
  local reversion = -deviation * (cycleTuning.reversionBase + math.min(absDeviation, cycleTuning.reversionDeviationCap) * cycleTuning.reversionDeviationScale)
  economy.momentum = economy.momentum + reversion * cycleDays

  economy.index = clamp(economy.index + economy.momentum * cycleDays, MIN_INDEX, MAX_INDEX)

  local eventModifier = getActiveEventModifier(economy.globalEvents, "modifier")
  economy.index = clamp(economy.index + eventModifier * cycleDays, MIN_INDEX, MAX_INDEX)

  -- Direct anchor toward 1.0 so the global economy keeps returning to "normal" after shocks and cycles.
  deviation = economy.index - 1.0
  economy.index = clamp(economy.index - deviation * GLOBAL_INDEX_ANCHOR_PULL * cycleDays, MIN_INDEX, MAX_INDEX)

  advancePhaseIfDue(economy)

  economy.lastUpdate = accumulatedSimTime
end

local function applyImpulseShocks()
  if not economyData or math.random() >= IMPULSE_PROB_PER_TICK then return end

  local direction = getCounterTrendImpulseDirection(economyData.index)
  local magnitude = randomShockMagnitude(IMPULSE_GLOBAL_MIN, IMPULSE_GLOBAL_MAX, IMPULSE_LARGE_MOVE_PROB)
  local delta = magnitude * direction

  economyData.index = clamp(economyData.index + delta, MIN_INDEX, MAX_INDEX)
  economyData.momentum = economyData.momentum * IMPULSE_MOMENTUM_DAMP

  generateImpulseArticle(delta)
end

-- Sub-markets ----------------------------------------------------------------------------------------

-- Follows the global index with a lag and sensitivity, plus noise and its own events.
local function updateSubMarket(market, config)
  if not market or not config then return end

  -- Lag: approximate lagged index using momentum projection.
  local lagSim = config.lagDays * SIM_SECONDS_PER_GAME_DAY
  local laggedIndex = economyData.index + (economyData.momentum * (lagSim / SIM_SECONDS_PER_GAME_DAY))
  laggedIndex = clamp(laggedIndex, MIN_INDEX, MAX_INDEX)

  local baseDeviation = (laggedIndex - 1.0) * config.sensitivity
  local targetIndex = 1.0 + baseDeviation

  local noise = (math.random() - 0.5) * 2 * config.noiseRange
  market.noise = noise

  local eventModifier = getActiveEventModifier(market.activeEvents, "modifier")

  market.index = clamp(targetIndex + noise + eventModifier, MIN_INDEX, MAX_INDEX)
  market.lastUpdate = accumulatedSimTime
end

local function applySubMarketImpulse(marketKey, config)
  if not economyData or not config then return end
  local market = economyData[marketKey]
  if not market or math.random() >= SUB_MARKET_IMPULSE_PROB then return end

  local direction = getCounterTrendImpulseDirection(market.index)
  local magnitude = randomShockMagnitude(SUB_MARKET_IMPULSE_MIN, SUB_MARKET_IMPULSE_MAX, SUB_MARKET_IMPULSE_LARGE_MOVE_PROB) * (config.impulseScale or 1.0)
  local delta = magnitude * direction

  market.index = clamp(market.index + delta, MIN_INDEX, MAX_INDEX)
  market.noise = (market.noise or 0) + delta
end

-- History --------------------------------------------------------------------------------------------

local function newMarketHistory()
  return { global = {}, jobs = {}, housing = {}, vehicles = {} }
end

local function recordHistory()
  if not economyData then return end
  if not economyData.history then economyData.history = newMarketHistory() end
  local history = economyData.history
  table.insert(history.global, economyData.index)
  table.insert(history.jobs, economyData.jobMarket.index)
  table.insert(history.housing, economyData.housingMarket.index)
  table.insert(history.vehicles, economyData.vehicleMarket.index)
  for _, key in ipairs({"global", "jobs", "housing", "vehicles"}) do
    while #history[key] > MAX_HISTORY do table.remove(history[key], 1) end
  end
end

-- Initialization -------------------------------------------------------------------------------------

local function newSubMarket(defaults, index)
  return {
    index = index,
    sensitivity = defaults.sensitivity,
    lagDays = defaults.lagDays,
    noiseRange = defaults.noiseRange,
    noise = 0,
    activeEvents = {},
    lastUpdate = 0,
  }
end

-- Random draws here (starting index, phase progress, phase duration) keep their order for replays.
local function getDefaultEconomyData(startingIndex)
  local index = startingIndex or (0.5 + math.random() * 1.0)
  local phase
  if index > 1.2 then phase = "peak"
  elseif index >= 1.0 then phase = "growth"
  elseif index > 0.8 then phase = "decline"
  else phase = "trough" end

  local phaseProgress = math.random() * 0.3
  local phaseDuration = randomPhaseDuration(phase)
  return {
    index = index,
    momentum = PHASE_MOMENTUM[phase] or 0,
    cyclePhase = phase,
    phaseProgress = phaseProgress,
    phaseDuration = phaseDuration,
    lastUpdate = 0,
    globalEvents = {},
    housingMarket = newSubMarket(SUB_MARKET_DEFAULTS.housingMarket, 1.0),
    jobMarket = newSubMarket(SUB_MARKET_DEFAULTS.jobMarket, 1.0),
    vehicleMarket = newSubMarket(SUB_MARKET_DEFAULTS.vehicleMarket, 1.0),
  }
end

-- Persistence ----------------------------------------------------------------------------------------

-- Resolve the declared relative file, preserving the supplied base's spelling and separators.
local function saveFilePath(currentSavePath)
  if not savePathFeature then
    savePathFeature = saveStore.bind(overhaul_career_saveSystem).feature("economy.globalEconomy", {
      owner = "overhaul_career_economy_globalEconomy",
      files = {"career/rls_career/globalEconomy.json"},
      phase = "profile",
      root = "slot",
      required = true,
    })
  end
  return currentSavePath .. "/" .. savePathFeature.path("")
end

-- Fills in fields that older saves do not have, so a loaded economy always has every market.
local function loadEconomy()
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  local data = jsonReadFile(saveFilePath(currentSavePath))
  if data and data.index then
    economyData = data
    if not economyData.history then economyData.history = newMarketHistory() end
    if not economyData.articles then economyData.articles = {} end
    if not economyData.globalEvents then economyData.globalEvents = {} end
    for _, key in ipairs(SUB_MARKET_KEYS) do
      if economyData[key] then
        economyData[key].activeEvents = economyData[key].activeEvents or {}
      else
        economyData[key] = newSubMarket(SUB_MARKET_DEFAULTS[key], economyData.index)
      end
    end
    accumulatedSimTime = economyData.lastUpdate or 0
    timeSinceLastUpdate = economyData.timeSinceLastUpdate or 0
  else
    economyData = getDefaultEconomyData()
  end
end

local function saveEconomy(currentSavePath, writer)
  if not economyData then return end
  if not currentSavePath then return end
  ensureDir.parentOf(writer, saveFilePath(currentSavePath))
  economyData.timeSinceLastUpdate = timeSinceLastUpdate
  overhaul_career_saveSystem.jsonWriteFileSafe(saveFilePath(currentSavePath), economyData, true)
end

-- Index and price readers ----------------------------------------------------------------------------

local function getGlobalIndex()
  return economyData and economyData.index or 1.0
end

local function getJobMarketIndex()
  return economyData and economyData.jobMarket and economyData.jobMarket.index or 1.0
end

local function getVehicleMarketIndex()
  return economyData and economyData.vehicleMarket and economyData.vehicleMarket.index or 1.0
end

local function getHousingMarketIndex()
  return economyData and economyData.housingMarket and economyData.housingMarket.index or 1.0
end

local function getVehicleBuyMultiplier()
  return getVehicleMarketIndex()
end

local function getVehicleSellMultiplier()
  local index = getVehicleMarketIndex()
  if index < 0.85 then
    return index * 0.85
  else
    return index * 0.95
  end
end

local function hasLiveEvent(events, eventId)
  for _, event in ipairs(events or {}) do
    if event.id == eventId and accumulatedSimTime <= (event.startTime or 0) + (event.durationSim or 0) then
      return true
    end
  end
  return false
end

local function getPartPriceMultiplier()
  local multiplier = 1.0
  if not economyData then return multiplier end
  if hasLiveEvent(economyData.vehicleMarket.activeEvents, "parts_shortage") then
    multiplier = multiplier * 1.15
  end
  if hasLiveEvent(economyData.jobMarket.activeEvents, "racing_season") then
    multiplier = multiplier * 1.10
  end
  return multiplier
end

local function getFuelPriceMultiplier()
  local multiplier = getGlobalIndex()
  if not economyData then return multiplier end
  if hasLiveEvent(economyData.jobMarket.activeEvents, "fuel_spike") then
    return multiplier * 1.15
  end
  return multiplier
end

local function getInsurancePriceMultiplier()
  local multiplier = getGlobalIndex()
  if not economyData then return multiplier end
  if hasLiveEvent(economyData.vehicleMarket.activeEvents, "insurance_hike") then
    return multiplier * 1.10
  end
  return multiplier
end

local function getMarketHistory()
  if not economyData or not economyData.history then return newMarketHistory() end
  return economyData.history
end

local function getNewsArticles()
  if not economyData or not economyData.articles then return {} end
  return economyData.articles
end

-- Market watch ---------------------------------------------------------------------------------------

local function requestMarketWatchData()
  if not overhaul_career_career.isActive() then return end
  if not economyData then return end
  local data = {
    history = getMarketHistory(),
    articles = getNewsArticles(),
    currentIndices = {
      global = economyData.index,
      jobs = economyData.jobMarket.index,
      housing = economyData.housingMarket.index,
      vehicles = economyData.vehicleMarket.index,
    },
    cyclePhase = economyData.cyclePhase,
    simTime = accumulatedSimTime,
  }
  -- Opportunity economy job market (per-job pressure) from activityHeat.
  local ok, summary = pcall(overhaul_career_economy_activityHeat.getMarketSummary)
  if ok then
    data.jobSurges = summary
  else
    log("E", "globalEconomy", "activityHeat.getMarketSummary failed: " .. tostring(summary))
  end
  guihooks.trigger("MarketWatchData", data)
end

-- Per-frame update -----------------------------------------------------------------------------------

local function runEconomyTickCore(elapsed, requestMarketWatch)
  previousIndices = {
    global = economyData.index,
    jobs = economyData.jobMarket.index,
    housing = economyData.housingMarket.index,
    vehicles = economyData.vehicleMarket.index,
  }
  local previousPhase = economyData.cyclePhase

  updateGlobalIndex(elapsed)
  applyImpulseShocks()

  updateSubMarket(economyData.housingMarket, SUB_MARKET_DEFAULTS.housingMarket)
  updateSubMarket(economyData.jobMarket, SUB_MARKET_DEFAULTS.jobMarket)
  updateSubMarket(economyData.vehicleMarket, SUB_MARKET_DEFAULTS.vehicleMarket)

  applySubMarketImpulse("housingMarket", SUB_MARKET_DEFAULTS.housingMarket)
  applySubMarketImpulse("jobMarket", SUB_MARKET_DEFAULTS.jobMarket)
  applySubMarketImpulse("vehicleMarket", SUB_MARKET_DEFAULTS.vehicleMarket)

  rollEvents(economyData.globalEvents, GLOBAL_EVENTS)
  rollEvents(economyData.jobMarket.activeEvents, JOB_EVENTS)
  rollEvents(economyData.vehicleMarket.activeEvents, VEHICLE_EVENTS)
  rollEvents(economyData.housingMarket.activeEvents, HOUSING_EVENTS)

  if economyData.cyclePhase ~= previousPhase then
    generatePhaseTransitionArticle(economyData.cyclePhase)
  end
  generateThresholdArticles()

  recordHistory()

  overhaul_world_fuel_fuelPrice.onEconomyUpdated()

  if requestMarketWatch then
    requestMarketWatchData()
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not overhaul_career_career.isActive() then return end
  if not economyData then return end

  accumulatedSimTime = accumulatedSimTime + dtSim
  timeSinceLastUpdate = timeSinceLastUpdate + dtSim

  if timeSinceLastUpdate >= UPDATE_INTERVAL_SIM then
    local elapsed = timeSinceLastUpdate
    timeSinceLastUpdate = 0
    runEconomyTickCore(elapsed, false)
  end
end

-- Lifecycle ------------------------------------------------------------------------------------------

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  saveEconomy(currentSavePath, writer)
end

local function onExtensionLoaded()
  loadEconomy()
end

local function onCareerActivated()
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  if FS:fileExists(saveFilePath(currentSavePath)) then
    loadEconomy()
  else
    economyData = getDefaultEconomyData()
    generateStartingArticle()
    recordHistory()
  end
end

-- Public API -----------------------------------------------------------------------------------------

M.getGlobalIndex = getGlobalIndex
M.getJobMarketIndex = getJobMarketIndex
M.getVehicleMarketIndex = getVehicleMarketIndex
M.getHousingMarketIndex = getHousingMarketIndex
M.getVehicleBuyMultiplier = getVehicleBuyMultiplier
M.getVehicleSellMultiplier = getVehicleSellMultiplier
M.getPartPriceMultiplier = getPartPriceMultiplier
M.getFuelPriceMultiplier = getFuelPriceMultiplier
M.getInsurancePriceMultiplier = getInsurancePriceMultiplier
M.requestMarketWatchData = requestMarketWatchData

-- Game hooks -----------------------------------------------------------------------------------------

M.onUpdate = onUpdate
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onExtensionLoaded = onExtensionLoaded
M.onCareerActivated = onCareerActivated

return M
