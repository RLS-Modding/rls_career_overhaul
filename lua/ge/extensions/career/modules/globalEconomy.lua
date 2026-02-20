local M = {}
M.dependencies = { 'career_career', 'career_saveSystem' }

-- Constants
local SIM_SECONDS_PER_GAME_DAY = 1200
local UPDATE_INTERVAL_SIM = 300           -- Update every 5 minutes (sim-seconds)
local MIN_INDEX = 0.5
local MAX_INDEX = math.huge

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/globalEconomy.json"

-- Phase duration ranges (sim-seconds)
local PHASE_DURATIONS = {
  growth  = { 10 * SIM_SECONDS_PER_GAME_DAY, 25 * SIM_SECONDS_PER_GAME_DAY },
  peak    = {  5 * SIM_SECONDS_PER_GAME_DAY, 12 * SIM_SECONDS_PER_GAME_DAY },
  decline = {  8 * SIM_SECONDS_PER_GAME_DAY, 20 * SIM_SECONDS_PER_GAME_DAY },
  trough  = {  5 * SIM_SECONDS_PER_GAME_DAY, 15 * SIM_SECONDS_PER_GAME_DAY },
}
local PHASE_ORDER = { "growth", "peak", "decline", "trough" }

-- Momentum curves per phase
local PHASE_MOMENTUM = {
  growth  =  0.003,
  peak    =  0.0,
  decline = -0.003,
  trough  =  0.0,
}

-- Sub-market config templates
local SUB_MARKET_DEFAULTS = {
  housingMarket = { sensitivity = 0.7, lagDays = 5,  noiseRange = 0.02 },
  jobMarket     = { sensitivity = 1.3, lagDays = -2, noiseRange = 0.03 },
  vehicleMarket = { sensitivity = 0.8, lagDays = 3,  noiseRange = 0.02 },
}

-- History & News
local MAX_HISTORY = 10
local MAX_ARTICLES = 20

-- Runtime state
local economyData = nil
local accumulatedSimTime = 0
local timeSinceLastUpdate = 0
local previousIndices = nil  -- snapshot of indices before tick for change detection

-- ── Helpers ──

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function randomInRange(lo, hi) return lo + math.random() * (hi - lo) end

local function randomPhaseDuration(phase)
  local range = PHASE_DURATIONS[phase]
  return randomInRange(range[1], range[2])
end

local function nextPhase(phase)
  for i, p in ipairs(PHASE_ORDER) do
    if p == phase then return PHASE_ORDER[(i % #PHASE_ORDER) + 1] end
  end
  return "growth"
end

-- ── Event system ──

local function getActiveEventModifier(events, fieldName)
  local mod = 0
  if not events then return mod end
  for i = #events, 1, -1 do
    local e = events[i]
    if accumulatedSimTime > (e.startTime or 0) + (e.durationSim or 0) then
      table.remove(events, i)
    else
      mod = mod + (e[fieldName or "modifier"] or 0)
    end
  end
  return mod
end

local function addEvent(targetEvents, event)
  event.startTime = event.startTime or accumulatedSimTime
  table.insert(targetEvents, event)
end

-- ── Global Index Update ──

local function updateGlobalIndex(dtSim)
  local d = economyData
  if not d then return end
  local cycleDays = dtSim / SIM_SECONDS_PER_GAME_DAY
  local deviation = d.index - 1.0
  local absDeviation = math.abs(deviation)

  -- Advance phase progress
  d.phaseProgress = d.phaseProgress + (dtSim / d.phaseDuration)

  -- Momentum adjustment based on phase
  if d.cyclePhase == "peak" then
    d.momentum = d.momentum * (1 - 0.12 * cycleDays)
    -- Force rollover pressure when overheated so booms can actually break.
    if d.index > 1.2 then
      d.momentum = d.momentum - (0.0008 + (d.index - 1.2) * 0.0012) * cycleDays
    end
    if math.abs(d.momentum) < 0.0002 then d.momentum = 0 end
  elseif d.cyclePhase == "trough" then
    d.momentum = d.momentum * (1 - 0.10 * cycleDays)
    if math.abs(d.momentum) < 0.0002 then d.momentum = 0 end
  else
    local baseMomentum = PHASE_MOMENTUM[d.cyclePhase] or 0
    if d.cyclePhase == "growth" and deviation > 0 then
      baseMomentum = baseMomentum * (1 - math.min(deviation, 1.5) * 0.7)
    elseif d.cyclePhase == "decline" and deviation > 0 then
      baseMomentum = baseMomentum - math.min(deviation, 2.0) * 0.0025
    end
    local noise = (math.random() - 0.5) * 0.001
    d.momentum = d.momentum + (baseMomentum - d.momentum) * 0.05 + noise
  end

  -- Mean reversion keeps long-term drift in check without hard-capping highs.
  local reversion = -deviation * (0.001 + math.min(absDeviation, 2.0) * 0.0015)
  d.momentum = d.momentum + reversion * cycleDays

  -- Apply momentum to index
  d.index = clamp(d.index + d.momentum * cycleDays, MIN_INDEX, MAX_INDEX)

  -- Apply global events
  local eventMod = getActiveEventModifier(d.globalEvents, "modifier")
  d.index = clamp(d.index + eventMod * cycleDays, MIN_INDEX, MAX_INDEX)

  -- Phase transition check
  if d.phaseProgress >= 1.0 or
     (d.cyclePhase == "peak" and d.momentum <= 0 and d.phaseProgress > 0.3) or
     (d.cyclePhase == "trough" and d.momentum >= 0 and d.phaseProgress > 0.3) then
    d.cyclePhase = nextPhase(d.cyclePhase)
    d.phaseProgress = 0
    d.phaseDuration = randomPhaseDuration(d.cyclePhase)
    d.momentum = PHASE_MOMENTUM[d.cyclePhase]
  end

  d.lastUpdate = accumulatedSimTime
end

-- ── Sub-Market Update ──

local function updateSubMarket(market, config)
  if not market or not config then return end

  -- Lag: approximate lagged index using momentum projection
  local lagSim = config.lagDays * SIM_SECONDS_PER_GAME_DAY
  local laggedIndex = economyData.index + (economyData.momentum * (lagSim / SIM_SECONDS_PER_GAME_DAY))
  laggedIndex = clamp(laggedIndex, MIN_INDEX, MAX_INDEX)

  -- Apply sensitivity
  local baseDeviation = (laggedIndex - 1.0) * config.sensitivity
  local targetIndex = 1.0 + baseDeviation

  -- Apply noise
  local noise = (math.random() - 0.5) * 2 * config.noiseRange
  market.noise = noise

  -- Apply market-specific events
  local eventMod = getActiveEventModifier(market.activeEvents, "modifier")

  market.index = clamp(targetIndex + noise + eventMod, MIN_INDEX, MAX_INDEX)
  market.lastUpdate = accumulatedSimTime
end

-- ── Random Event Rolling ──

-- Event display names for notifications
local EVENT_DISPLAY_NAMES = {
  economic_stimulus  = "Economic Stimulus",
  recession_warning  = "Recession Warning",
  trade_deal         = "Trade Deal Signed",
  market_panic       = "Market Panic",
  tech_boom          = "Tech Boom",
  hiring_boom        = "Hiring Boom",
  layoff_wave        = "Layoff Wave",
  gig_surge          = "Gig Economy Surge",
  fuel_spike         = "Fuel Price Spike",
  racing_season      = "Racing Season",
  new_model_year     = "New Model Year Release",
  parts_shortage     = "Parts Shortage",
  insurance_hike     = "Insurance Rate Hike",
  car_show           = "Car Show in Town",
  fleet_sale         = "Fleet Sale",
  road_construction  = "Road Construction Nearby",
  new_business_opens = "New Business Opens",
  crime_wave         = "Crime Wave",
  housing_boom       = "Housing Boom",
  market_correction  = "Market Correction",
  zoning_change      = "Zoning Change",
}

local GLOBAL_EVENTS = {
  { id = "economic_stimulus",  modifier =  0.008, durationDaysMin = 10, durationDaysMax = 20, probability = 0.03 },
  { id = "recession_warning",  modifier = -0.006, durationDaysMin = 5,  durationDaysMax = 15, probability = 0.04 },
  { id = "trade_deal",         modifier =  0.004, durationDaysMin = 7,  durationDaysMax = 12, probability = 0.03 },
  { id = "market_panic",       modifier = -0.012, durationDaysMin = 3,  durationDaysMax = 5,  probability = 0.02 },
  { id = "tech_boom",          modifier =  0.010, durationDaysMin = 10, durationDaysMax = 20, probability = 0.02 },
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

local function hasActiveEvent(events, eventId)
  for _, e in ipairs(events or {}) do
    if e.id == eventId then return true end
  end
  return false
end

local generateEventArticle -- forward declaration

local function rollEvents(targetEvents, eventDefs)
  for _, def in ipairs(eventDefs) do
    if not hasActiveEvent(targetEvents, def.id) and math.random() < def.probability then
      local durationDays = randomInRange(def.durationDaysMin, def.durationDaysMax)
      addEvent(targetEvents, {
        id = def.id,
        modifier = def.modifier,
        durationSim = durationDays * SIM_SECONDS_PER_GAME_DAY,
      })
      -- Generate news article for this event
      generateEventArticle(def.id)
    end
  end
end

-- ── History Tracking ──

local function recordHistory()
  if not economyData then return end
  if not economyData.history then economyData.history = { global = {}, jobs = {}, housing = {}, vehicles = {} } end
  local h = economyData.history
  table.insert(h.global, economyData.index)
  table.insert(h.jobs, economyData.jobMarket.index)
  table.insert(h.housing, economyData.housingMarket.index)
  table.insert(h.vehicles, economyData.vehicleMarket.index)
  -- Trim to MAX_HISTORY
  for _, key in ipairs({"global", "jobs", "housing", "vehicles"}) do
    while #h[key] > MAX_HISTORY do table.remove(h[key], 1) end
  end
end

-- ── News Article Generation ──

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

local function addArticle(headline, body, sector)
  if not economyData then return end
  if not economyData.articles then economyData.articles = {} end
  table.insert(economyData.articles, {
    timestamp = accumulatedSimTime,
    headline = headline,
    body = body,
    sector = sector or "global",
  })
  -- Trim to MAX_ARTICLES
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

local function generateThresholdArticles()
  if not economyData then return end
  -- Check for boom conditions (index > 1.2)
  if economyData.index > 1.2 and previousIndices and previousIndices.global <= 1.2 then
    local article = BOOM_ARTICLES[math.random(#BOOM_ARTICLES)]
    addArticle(article.headline, article.body, article.sector)
  end
  -- Check for recession conditions (index < 0.8)
  if economyData.index < 0.8 and previousIndices and previousIndices.global >= 0.8 then
    local article = RECESSION_ARTICLES[math.random(#RECESSION_ARTICLES)]
    addArticle(article.headline, article.body, article.sector)
  end
end

generateEventArticle = function(eventId)
  local article = EVENT_ARTICLES[eventId]
  if article then
    addArticle(article.headline, article.body, article.sector)
  end
end

local function generateStartingArticle()
  if not economyData then return end
  local idx = economyData.index
  local condition
  if idx > 1.2 then condition = "booming"
  elseif idx > 1.05 then condition = "healthy"
  elseif idx > 0.95 then condition = "stable"
  elseif idx > 0.8 then condition = "sluggish"
  else condition = "struggling" end

  local headlines = {
    booming = "State of the Economy: Boom Times",
    healthy = "State of the Economy: Looking Good",
    stable = "State of the Economy: Steady as She Goes",
    sluggish = "State of the Economy: Slow Going",
    struggling = "State of the Economy: Tough Times Ahead",
  }
  local bodies = {
    booming = "Welcome! The economy is running hot right now. Jobs pay well, but expect higher prices on vehicles and property. A good time to earn and save.",
    healthy = "Welcome! Economic conditions are favorable. Jobs are available, prices are fair, and there are opportunities for those willing to work hard.",
    stable = "Welcome! The economy is in a neutral state — nothing spectacular, but nothing to worry about either. A balanced time to start building your career.",
    sluggish = "Welcome! The economy is a bit slow right now. Jobs may pay less, but you'll find better deals on vehicles and property. Every cloud has a silver lining.",
    struggling = "Welcome! Times are tough out there. Work pays less and jobs are scarce, but vehicle and property prices are rock bottom. Buy low, sell high later.",
  }
  addArticle(headlines[condition], bodies[condition], "global")
end

-- ── Initialization ──

local function getDefaultEconomyData(startingIndex)
  local idx = startingIndex or (0.5 + math.random() * 1.0)
  local phase
  if idx > 1.2 then phase = "peak"
  elseif idx >= 1.0 then phase = "growth"
  elseif idx > 0.8 then phase = "decline"
  else phase = "trough" end

  return {
    index = idx,
    momentum = PHASE_MOMENTUM[phase] or 0,
    cyclePhase = phase,
    phaseProgress = math.random() * 0.3,
    phaseDuration = randomPhaseDuration(phase),
    lastUpdate = 0,
    globalEvents = {},

    housingMarket = {
      index = 1.0, sensitivity = 0.7, lagDays = 5, noiseRange = 0.02,
      noise = 0, activeEvents = {}, lastUpdate = 0,
    },
    jobMarket = {
      index = 1.0, sensitivity = 1.3, lagDays = -2, noiseRange = 0.03,
      noise = 0, activeEvents = {}, lastUpdate = 0,
    },
    vehicleMarket = {
      index = 1.0, sensitivity = 0.8, lagDays = 3, noiseRange = 0.02,
      noise = 0, activeEvents = {}, lastUpdate = 0,
    },
  }
end

-- ── Save / Load ──

local function ensureSaveDir(currentSavePath)
  local dirPath = currentSavePath .. saveDir
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
end

local function loadEconomy()
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  local data = jsonReadFile(currentSavePath .. saveFile)
  if data and data.index then
    economyData = data
    -- Migration: add missing fields
    if not economyData.history then economyData.history = { global = {}, jobs = {}, housing = {}, vehicles = {} } end
    if not economyData.articles then economyData.articles = {} end
    if not economyData.globalEvents then economyData.globalEvents = {} end
    -- Ensure activeEvents exists on pre-existing sub-markets
    for _, key in ipairs({"housingMarket", "jobMarket", "vehicleMarket"}) do
      if economyData[key] then
        economyData[key].activeEvents = economyData[key].activeEvents or {}
      end
    end
    if not economyData.housingMarket then
      economyData.housingMarket = { index = economyData.index, sensitivity = 0.7, lagDays = 5, noiseRange = 0.02, noise = 0, activeEvents = {}, lastUpdate = 0 }
    end
    if not economyData.jobMarket then
      economyData.jobMarket = { index = economyData.index, sensitivity = 1.3, lagDays = -2, noiseRange = 0.03, noise = 0, activeEvents = {}, lastUpdate = 0 }
    end
    if not economyData.vehicleMarket then
      economyData.vehicleMarket = { index = economyData.index, sensitivity = 0.8, lagDays = 3, noiseRange = 0.02, noise = 0, activeEvents = {}, lastUpdate = 0 }
    end
    accumulatedSimTime = economyData.lastUpdate or 0
    timeSinceLastUpdate = economyData.timeSinceLastUpdate or 0
  else
    economyData = getDefaultEconomyData()
  end
end

local function saveEconomy(currentSavePath)
  if not economyData then return end
  if not currentSavePath then
    local _, p = career_saveSystem.getCurrentSaveSlot()
    currentSavePath = p
    if not currentSavePath then return end
  end
  ensureSaveDir(currentSavePath)
  economyData.timeSinceLastUpdate = timeSinceLastUpdate
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, economyData, true)
end

-- ── Public API ──

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
  local idx = getVehicleMarketIndex()
  if idx < 0.85 then
    return idx * 0.85
  else
    return idx * 0.95
  end
end

local function getPartPriceMultiplier()
  local mult = 1.0
  if not economyData then return mult end
  local function hasEvent(events, id)
    for _, e in ipairs(events or {}) do
      if e.id == id and accumulatedSimTime <= (e.startTime or 0) + (e.durationSim or 0) then
        return true
      end
    end
    return false
  end
  if hasEvent(economyData.vehicleMarket.activeEvents, "parts_shortage") then
    mult = mult * 1.15
  end
  if hasEvent(economyData.jobMarket.activeEvents, "racing_season") then
    mult = mult * 1.10
  end
  return mult
end

local function getFuelPriceMultiplier()
  local mult = getGlobalIndex()
  if not economyData then return mult end
  for _, e in ipairs(economyData.jobMarket.activeEvents or {}) do
    if e.id == "fuel_spike" and accumulatedSimTime <= (e.startTime or 0) + (e.durationSim or 0) then
      return mult * 1.15
    end
  end
  return mult
end

local function getInsurancePriceMultiplier()
  local mult = getGlobalIndex()
  if not economyData then return mult end
  for _, e in ipairs(economyData.vehicleMarket.activeEvents or {}) do
    if e.id == "insurance_hike" and accumulatedSimTime <= (e.startTime or 0) + (e.durationSim or 0) then
      return mult * 1.10
    end
  end
  return mult
end

local function getCyclePhase()
  return economyData and economyData.cyclePhase or "growth"
end

local function getMomentum()
  return economyData and economyData.momentum or 0
end

local function getEconomySummary()
  if not economyData then return {} end
  return {
    globalIndex = economyData.index,
    momentum = economyData.momentum,
    cyclePhase = economyData.cyclePhase,
    phaseProgress = economyData.phaseProgress,
    jobMarketIndex = economyData.jobMarket.index,
    vehicleMarketIndex = economyData.vehicleMarket.index,
    housingMarketIndex = economyData.housingMarket.index,
    globalEvents = economyData.globalEvents,
    jobEvents = economyData.jobMarket.activeEvents,
    vehicleEvents = economyData.vehicleMarket.activeEvents,
    housingEvents = economyData.housingMarket.activeEvents,
  }
end

local function getMarketHistory()
  if not economyData or not economyData.history then return { global = {}, jobs = {}, housing = {}, vehicles = {} } end
  return economyData.history
end

local function getNewsArticles()
  if not economyData or not economyData.articles then return {} end
  return economyData.articles
end

local function requestMarketWatchData()
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
  if guihooks and guihooks.trigger then
    guihooks.trigger("MarketWatchData", data)
  end
end

local function setStartingIndex(idx)
  idx = clamp(idx, MIN_INDEX, MAX_INDEX)
  economyData = getDefaultEconomyData(idx)
end

local function performEconomyTick()
  if not career_career or not career_career.isActive() then return false end
  if not economyData then return false end

  local elapsed = UPDATE_INTERVAL_SIM
  accumulatedSimTime = accumulatedSimTime + elapsed
  timeSinceLastUpdate = 0

  previousIndices = {
    global = economyData.index,
    jobs = economyData.jobMarket.index,
    housing = economyData.housingMarket.index,
    vehicles = economyData.vehicleMarket.index,
  }
  local previousPhase = economyData.cyclePhase

  updateGlobalIndex(elapsed)

  updateSubMarket(economyData.housingMarket, SUB_MARKET_DEFAULTS.housingMarket)
  updateSubMarket(economyData.jobMarket, SUB_MARKET_DEFAULTS.jobMarket)
  updateSubMarket(economyData.vehicleMarket, SUB_MARKET_DEFAULTS.vehicleMarket)

  rollEvents(economyData.globalEvents, GLOBAL_EVENTS)
  rollEvents(economyData.jobMarket.activeEvents, JOB_EVENTS)
  rollEvents(economyData.vehicleMarket.activeEvents, VEHICLE_EVENTS)
  rollEvents(economyData.housingMarket.activeEvents, HOUSING_EVENTS)

  if economyData.cyclePhase ~= previousPhase then
    generatePhaseTransitionArticle(economyData.cyclePhase)
  end
  generateThresholdArticles()

  recordHistory()

  if freeroam_facilities_fuelPrice and freeroam_facilities_fuelPrice.onEconomyUpdated then
    freeroam_facilities_fuelPrice.onEconomyUpdated()
  end

  saveEconomy()
  
  requestMarketWatchData()
  return true
end

-- ── Hooks ──

local function onUpdate(dtReal, dtSim, dtRaw)
  if not career_career or not career_career.isActive() then return end
  if not economyData then return end

  accumulatedSimTime = accumulatedSimTime + dtSim
  timeSinceLastUpdate = timeSinceLastUpdate + dtSim

  if timeSinceLastUpdate >= UPDATE_INTERVAL_SIM then
    local elapsed = timeSinceLastUpdate
    timeSinceLastUpdate = 0

    previousIndices = {
      global = economyData.index,
      jobs = economyData.jobMarket.index,
      housing = economyData.housingMarket.index,
      vehicles = economyData.vehicleMarket.index,
    }
    local previousPhase = economyData.cyclePhase

    updateGlobalIndex(elapsed)

    updateSubMarket(economyData.housingMarket, SUB_MARKET_DEFAULTS.housingMarket)
    updateSubMarket(economyData.jobMarket, SUB_MARKET_DEFAULTS.jobMarket)
    updateSubMarket(economyData.vehicleMarket, SUB_MARKET_DEFAULTS.vehicleMarket)

    rollEvents(economyData.globalEvents, GLOBAL_EVENTS)
    rollEvents(economyData.jobMarket.activeEvents, JOB_EVENTS)
    rollEvents(economyData.vehicleMarket.activeEvents, VEHICLE_EVENTS)
    rollEvents(economyData.housingMarket.activeEvents, HOUSING_EVENTS)

    if economyData.cyclePhase ~= previousPhase then
      generatePhaseTransitionArticle(economyData.cyclePhase)
    end
    generateThresholdArticles()

    recordHistory()

    if freeroam_facilities_fuelPrice and freeroam_facilities_fuelPrice.onEconomyUpdated then
      freeroam_facilities_fuelPrice.onEconomyUpdated()
    end

    saveEconomy()
  end
end

local function onSaveCurrentSaveSlot(currentSavePath)
  saveEconomy(currentSavePath)
end

local function onExtensionLoaded()
  loadEconomy()
end

local function onCareerActivated()
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  if FS:fileExists(currentSavePath .. saveFile) then
    loadEconomy()
  else
    economyData = getDefaultEconomyData()
    generateStartingArticle()
    recordHistory()
    saveEconomy(currentSavePath)
  end
end

-- ── Exports ──

M.getGlobalIndex = getGlobalIndex
M.getJobMarketIndex = getJobMarketIndex
M.getVehicleMarketIndex = getVehicleMarketIndex
M.getHousingMarketIndex = getHousingMarketIndex
M.getVehicleBuyMultiplier = getVehicleBuyMultiplier
M.getVehicleSellMultiplier = getVehicleSellMultiplier
M.getPartPriceMultiplier = getPartPriceMultiplier
M.getFuelPriceMultiplier = getFuelPriceMultiplier
M.getInsurancePriceMultiplier = getInsurancePriceMultiplier
M.getCyclePhase = getCyclePhase
M.getMomentum = getMomentum
M.getEconomySummary = getEconomySummary
M.setStartingIndex = setStartingIndex
M.getDefaultEconomyData = getDefaultEconomyData
M.getMarketHistory = getMarketHistory
M.getNewsArticles = getNewsArticles
M.requestMarketWatchData = requestMarketWatchData
M.performEconomyTick = performEconomyTick

M.onUpdate = onUpdate
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onExtensionLoaded = onExtensionLoaded
M.onCareerActivated = onCareerActivated

return M
