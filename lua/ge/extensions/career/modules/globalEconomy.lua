local M = {}
M.dependencies = { 'career_career', 'career_saveSystem' }

-- Constants
local SIM_SECONDS_PER_GAME_DAY = 1200
local UPDATE_INTERVAL_SIM = 1200          -- Update every 1 game day (1200 sim-seconds)
local MIN_INDEX = 0.5
local MAX_INDEX = 1.5

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

-- Runtime state
local economyData = nil
local accumulatedSimTime = 0
local timeSinceLastUpdate = 0

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

  -- Advance phase progress
  d.phaseProgress = d.phaseProgress + (dtSim / d.phaseDuration)

  -- Momentum adjustment based on phase
  if d.cyclePhase == "peak" then
    d.momentum = d.momentum * (1 - 0.1 * (dtSim / SIM_SECONDS_PER_GAME_DAY))
    if d.momentum < 0.0002 then d.momentum = 0 end
  elseif d.cyclePhase == "trough" then
    d.momentum = d.momentum * (1 - 0.1 * (dtSim / SIM_SECONDS_PER_GAME_DAY))
    if math.abs(d.momentum) < 0.0002 then d.momentum = 0 end
  else
    local baseMomentum = PHASE_MOMENTUM[d.cyclePhase] or 0
    local noise = (math.random() - 0.5) * 0.001
    d.momentum = d.momentum + (baseMomentum - d.momentum) * 0.05 + noise
  end

  -- Apply momentum to index
  d.index = clamp(d.index + d.momentum * (dtSim / SIM_SECONDS_PER_GAME_DAY), MIN_INDEX, MAX_INDEX)

  -- Apply global events
  local eventMod = getActiveEventModifier(d.globalEvents, "modifier")
  d.index = clamp(d.index + eventMod * (dtSim / SIM_SECONDS_PER_GAME_DAY), MIN_INDEX, MAX_INDEX)

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

local function rollEvents(targetEvents, eventDefs)
  for _, def in ipairs(eventDefs) do
    if not hasActiveEvent(targetEvents, def.id) and math.random() < def.probability then
      local durationDays = randomInRange(def.durationDaysMin, def.durationDaysMax)
      addEvent(targetEvents, {
        id = def.id,
        modifier = def.modifier,
        durationSim = durationDays * SIM_SECONDS_PER_GAME_DAY,
      })
      -- Phone notification
      if guihooks and guihooks.trigger then
        local displayName = EVENT_DISPLAY_NAMES[def.id] or def.id:gsub("_", " ")
        guihooks.trigger("toastrMsg", {
          type = def.modifier > 0 and "info" or "warning",
          title = "Economy News",
          msg = displayName,
        })
      end
    end
  end
end

-- ── Initialization ──

local function getDefaultEconomyData(startingIndex)
  local idx = startingIndex or (0.5 + math.random() * 1.0)
  local phase
  if idx > 1.2 then phase = "peak"
  elseif idx > 1.0 then phase = "growth"
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
    if not economyData.globalEvents then economyData.globalEvents = {} end
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

local function setStartingIndex(idx)
  idx = clamp(idx, MIN_INDEX, MAX_INDEX)
  economyData = getDefaultEconomyData(idx)
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

    -- 1. Update global index
    updateGlobalIndex(elapsed)

    -- 2. Update sub-markets
    updateSubMarket(economyData.housingMarket, SUB_MARKET_DEFAULTS.housingMarket)
    updateSubMarket(economyData.jobMarket, SUB_MARKET_DEFAULTS.jobMarket)
    updateSubMarket(economyData.vehicleMarket, SUB_MARKET_DEFAULTS.vehicleMarket)

    -- 3. Roll for new events
    rollEvents(economyData.globalEvents, GLOBAL_EVENTS)
    rollEvents(economyData.jobMarket.activeEvents, JOB_EVENTS)
    rollEvents(economyData.vehicleMarket.activeEvents, VEHICLE_EVENTS)
    rollEvents(economyData.housingMarket.activeEvents, HOUSING_EVENTS)

    -- 4. Auto-save
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
M.getCyclePhase = getCyclePhase
M.getMomentum = getMomentum
M.getEconomySummary = getEconomySummary
M.setStartingIndex = setStartingIndex
M.getDefaultEconomyData = getDefaultEconomyData

M.onUpdate = onUpdate
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onExtensionLoaded = onExtensionLoaded
M.onCareerActivated = onCareerActivated

return M
