local M = {}

local C = {
  NPC_PER_LOT_MULT = 1.25,
  NPC_COUNT_MIN = 3,
  NPC_CASH_POOL_BUFFER_MULT = 4.0,
  NPC_INTEREST_LOT_VALUE_HEADROOM = 1.75,
  NPC_VALUE_TOPUP_MIN_INTEREST = 0.14,
  PLAYER_LISTING_MIN_STRONG_BIDDERS = 5,
  PLAYER_LISTING_STRONG_BIDDER_FRAC = 0.72,
  PLAYER_LISTING_BID_CHANCE_BONUS = 0.12,
  NPC_MIN_CASH_FLOOR = 5000,
  NPC_MIN_SPEND_FRAC = 0.15,
  NPC_MAX_SPEND_FRAC = 0.85,
  NPC_PRIVATE_MULT_LOW = 0.75,
  NPC_PRIVATE_MULT_HIGH = 1.15,
  NPC_VALUATION_NOISE_MAX = 0.06,
  NPC_BID_INCREMENTS = {250, 500, 1000, 5000},
  BARGAIN_HUNTER_FRACTION = 0.3,
  NPC_FAVORITES_ONE_WEIGHT = 0.5,
  NPC_FAVORITE_INTEREST_LO = 0.72,
  NPC_FAVORITE_INTEREST_HI = 1.0,
  NPC_NONFAVORITE_INTEREST_MAX = 0.12,
  INTEREST_FOMO_STRENGTH = 0.10,
  INTEREST_CONTRARIAN_STRENGTH = 0.10,
  ROOM_HEAT_FRAC_VALUE_SCALE = 2.5,
  ROOM_HEAT_STEP_LOG_SCALE = 0.11,
  ROOM_HEAT_MAX_PER_BID = 0.42,
  ROOM_HEAT_DECAY_PER_SEC = 0.06,
  FOMO_PRICE_MULT_STRENGTH = 0.35,
  TIME_PRESSURE_RAMP_FRACTION = 0.65,
  TIME_PRESSURE_MIN_WINDOW = 8.0,
  TIME_PRESSURE_INTEREST_PER_SEC = 0.18,
  TIME_PRESSURE_INTEREST_MAX = 0.12,
  TIME_PRESSURE_BID_BONUS_MAX = 0.16,
  TIME_PRESSURE_MIN_DELAY_MULT = 0.65,
  TIME_PRESSURE_MIN_INTEREST_WEIGHT = 0.25,
  TIME_PRESSURE_EXTENSION_DAMP_PER = 0.12,
  NPC_MIN_GAP_AFTER_OWN_BID = 5.0,
  NPC_SCHED_DELAY_FLOOR = 1.0,
  NPC_SCHED_MIN_HIGH = 1.5,
  NPC_SCHED_MAX_HIGH = 5.0,
  NPC_SCHED_MIN_LOW = 6.0,
  NPC_SCHED_MAX_LOW = 14.0,
  NPC_BID_CHANCE_FLOOR = 0.08,
  NPC_BID_CHANCE_CEIL = 0.86,
  DUE_NPC_STAGGER_MIN = 0.08,
  DUE_NPC_STAGGER_MAX = 0.20,
  INCREMENT_BITE_LAMBDA = 7.5,
  INCREMENT_PRESSURE_AGGRESSION_BOOST = 0.38,
  INCREMENT_EARLY_AGGRESSION_MULT = 0.82,
  BARGAIN_HUNTER_BITE_PENALTY_EXP = 1.18,
  NPC_MOOD_INFLUENCE_ON_BASE = 0.15,
  NPC_MOOD_DECAY = 0.88,
  MOOD_DELTA_WON = -0.08,
  MOOD_DELTA_LOST_CHASE = 0.12,
  MOOD_DELTA_SAT_OUT = -0.03,
  MAX_BIDS_PER_FRAME = 1
}

local session = {
  host = nil,
  active = false
}

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function clamp01(v) return clamp(v, 0, 1) end

local function lerp(a, b, t) return a + (b - a) * clamp01(t) end

local function roundDown(value, step)
  local s = math.max(1, step or 1)
  return math.floor(math.max(0, value or 0) / s) * s
end

local function roundNearest(value, step)
  local s = math.max(1, step or 1)
  return math.floor(math.max(0, value or 0) / s + 0.5) * s
end

local function bidIncrementToHeatPulse(lot, incrementAmount)
  local inc = math.max(0, tonumber(incrementAmount) or 0)
  if inc <= 0 then return 0 end
  local base = math.max(tonumber(lot.basePrice) or 0, 1500)
  local step = math.max(tonumber(lot.minStep) or 250, 1)
  local fracCar = inc / base
  local vsStep = inc / step
  local pulse = C.ROOM_HEAT_FRAC_VALUE_SCALE * fracCar +
    C.ROOM_HEAT_STEP_LOG_SCALE * math.log(1 + vsStep)
  return clamp01(math.min(pulse, C.ROOM_HEAT_MAX_PER_BID))
end

local function applyBidHeatFromIncrement(lot, incrementAmount)
  if not lot then return end
  local p = bidIncrementToHeatPulse(lot, incrementAmount)
  if p > 0 then
    lot.roomHeat = clamp01((lot.roomHeat or 0) + p)
  end
end

local function personaFomoLeanMultiplier(persona)
  local pm = tonumber(persona and persona.priceMultiplier) or 1
  return clamp(1 + (pm - 1) * C.FOMO_PRICE_MULT_STRENGTH, 0.75, 1.35)
end

local function personaContrarianLeanMultiplier(persona)
  local pm = tonumber(persona and persona.priceMultiplier) or 1
  return clamp(1 + (1 - pm) * C.FOMO_PRICE_MULT_STRENGTH, 0.75, 1.35)
end

local function timePressure01(lot, now)
  if not lot then return 0 end
  local initialDuration = math.max(C.TIME_PRESSURE_MIN_WINDOW, tonumber(lot.initialLotDurationSec) or 0)
  if initialDuration <= 0 then return 0 end
  local timeLeft = math.max(0, (tonumber(lot.endTime) or now) - now)
  local rampWindow = math.max(C.TIME_PRESSURE_MIN_WINDOW, initialDuration * C.TIME_PRESSURE_RAMP_FRACTION)
  local extensionCount = math.max(0, tonumber(lot.extensionCount) or 0)
  local extensionDamp = math.max(0.55, 1 - extensionCount * C.TIME_PRESSURE_EXTENSION_DAMP_PER)
  return clamp01(1 - timeLeft / rampWindow) * extensionDamp
end

local function timePressureInterestWeight(interest)
  return lerp(C.TIME_PRESSURE_MIN_INTEREST_WEIGHT, 1.0, clamp01(interest))
end

local fallbackProfiles = {
  {name = 'Bidder A', pm = 0.92, cor = 0.75, unp = 0.06},
  {name = 'Bidder B', pm = 1.00, cor = 0.55, unp = 0.04},
  {name = 'Bidder C', pm = 1.08, cor = 0.82, unp = 0.08},
  {name = 'Bidder D', pm = 0.88, cor = 0.60, unp = 0.05},
  {name = 'Bidder E', pm = 1.04, cor = 0.70, unp = 0.07},
  {name = 'Bidder F', pm = 0.95, cor = 0.45, unp = 0.03},
  {name = 'Bidder G', pm = 1.10, cor = 0.85, unp = 0.09},
  {name = 'Bidder H', pm = 0.97, cor = 0.65, unp = 0.04},
  {name = 'Bidder I', pm = 1.02, cor = 0.50, unp = 0.06},
  {name = 'Bidder J', pm = 0.90, cor = 0.78, unp = 0.05},
}

local function makeFallbackPersonality(index)
  local p = fallbackProfiles[((index - 1) % #fallbackProfiles) + 1]
  return {name = p.name, priceMultiplier = p.pm, counterOfferReadiness = p.cor, unpredictability = p.unp}
end

local function getNpcCountForLotCount(lotCount)
  lotCount = math.max(0, math.floor(tonumber(lotCount) or 0))
  return math.max(C.NPC_COUNT_MIN, math.floor(lotCount * C.NPC_PER_LOT_MULT))
end

local function generatePersonas(lotCount)
  local count = getNpcCountForLotCount(lotCount)
  local personas = {}
  local usedNames = {}
  local bargainCount = math.max(1, math.floor(count * C.BARGAIN_HUNTER_FRACTION + 0.5))

  for i = 1, count do
    local personality
    if career_modules_marketplace and career_modules_marketplace.generatePersonality then
      personality = career_modules_marketplace.generatePersonality(true)
    end
    if type(personality) ~= 'table' then
      personality = makeFallbackPersonality(i)
    end

    local baseName = tostring(personality.name or ('Bidder ' .. tostring(i)))
    if baseName == '' then baseName = 'Bidder ' .. tostring(i) end
    local name = baseName
    local suffix = 2
    while usedNames[name] do
      name = string.format('%s %d', baseName, suffix)
      suffix = suffix + 1
    end
    usedNames[name] = true

    table.insert(personas, {
      id = string.format('npc_%d', i),
      name = name,
      archetype = personality.archetype,
      priceMultiplier = tonumber(personality.priceMultiplier) or 1.0,
      counterOfferReadiness = tonumber(personality.counterOfferReadiness) or 0.5,
      unpredictability = tonumber(personality.unpredictability) or 0.03,
      cashOnHand = 0,
      startingCash = 0,
      moodTilt = 0,
      isBargainHunter = i <= bargainCount
    })
  end
  return personas
end

local function lotBaseValue(lot)
  return math.max(500, math.floor(tonumber(lot.conditionedBasePrice) or tonumber(lot.basePrice) or 0))
end

local function ensurePersonasCanContestOpening(lot, personas)
  if not lot or not personas then
    return
  end
  local hurdle = (tonumber(lot.currentBid) or 0) + (tonumber(lot.minStep) or 250)
  local refCommitFrac = lerp(C.NPC_MIN_SPEND_FRAC, C.NPC_MAX_SPEND_FRAC, 0.40)
  local minForOpening = C.NPC_MIN_CASH_FLOOR
  if hurdle > 0 then
    minForOpening = math.max(minForOpening, math.ceil(hurdle / refCommitFrac))
  end
  local lotValue = lotBaseValue(lot)
  local headroom = C.NPC_INTEREST_LOT_VALUE_HEADROOM

  for _, p in ipairs(personas) do
    local need = minForOpening
    local intr = (lot.npcBaseInterestByPersonaId and tonumber(lot.npcBaseInterestByPersonaId[p.id])) or 0
    if intr >= C.NPC_VALUE_TOPUP_MIN_INTEREST then
      local frac = lerp(C.NPC_MIN_SPEND_FRAC, C.NPC_MAX_SPEND_FRAC, intr)
      local forValue = math.ceil((lotValue * headroom) / frac)
      if forValue > need then
        need = forValue
      end
    end
    local c = tonumber(p.cashOnHand) or 0
    if c < need then
      p.cashOnHand = need
    end
  end
end

local function computePersonaInterestMinCash(persona, lots, openingFloorPerPersona)
  local scored = {}
  for _, lot in ipairs(lots or {}) do
    local map = lot.npcBaseInterestByPersonaId or {}
    local intr = tonumber(map[persona.id]) or 0
    table.insert(scored, { interest = intr, lot = lot })
  end
  table.sort(scored, function(a, b)
    return a.interest > b.interest
  end)

  local stake = 0
  local headroom = C.NPC_INTEREST_LOT_VALUE_HEADROOM
  local picked = 0
  for i = 1, #scored do
    if picked >= 2 then
      break
    end
    if scored[i].interest < C.NPC_VALUE_TOPUP_MIN_INTEREST then
      break
    end
    local base = lotBaseValue(scored[i].lot)
    local frac = lerp(C.NPC_MIN_SPEND_FRAC, C.NPC_MAX_SPEND_FRAC, scored[i].interest)
    stake = stake + math.ceil((base * headroom) / frac)
    picked = picked + 1
  end
  return math.max(C.NPC_MIN_CASH_FLOOR, openingFloorPerPersona, stake)
end

local function allocateCash(personas, lots)
  local totalPreview = 0
  local maxPreview = 0
  for _, lot in ipairs(lots) do
    local pv = tonumber(lot.previewStartBid) or tonumber(lot.currentBid) or 0
    totalPreview = totalPreview + pv
    if pv > maxPreview then
      maxPreview = pv
    end
  end
  local pool = math.max(totalPreview * C.NPC_CASH_POOL_BUFFER_MULT, 50000)

  local minStep = 250
  local hurdle = maxPreview + minStep
  local refCommitFrac = lerp(C.NPC_MIN_SPEND_FRAC, C.NPC_MAX_SPEND_FRAC, 0.40)
  local openingFloor = math.max(C.NPC_MIN_CASH_FLOOR, math.ceil(hurdle / refCommitFrac))

  local personaFloors = {}
  local sumFloors = 0
  for _, persona in ipairs(personas) do
    local f = computePersonaInterestMinCash(persona, lots, openingFloor)
    personaFloors[persona.id] = f
    sumFloors = sumFloors + f
  end
  pool = math.max(pool, sumFloors)

  local weights, totalW = {}, 0
  for i = 1, #personas do
    weights[i] = 0.3 + math.random() * 0.7
    totalW = totalW + weights[i]
  end

  local extra = pool - sumFloors
  if extra < 0 then
    pool = sumFloors
    extra = 0
  end

  for i, persona in ipairs(personas) do
    local base = personaFloors[persona.id]
    persona.cashOnHand = math.floor(base + extra * (weights[i] / totalW))
    persona.startingCash = persona.cashOnHand
  end

  local actualSum = 0
  for _, p in ipairs(personas) do actualSum = actualSum + p.cashOnHand end
  if actualSum > 0 and math.abs(actualSum - pool) > #personas then
    local scale = pool / actualSum
    for _, p in ipairs(personas) do
      local floorP = personaFloors[p.id]
      p.cashOnHand = math.max(floorP, math.floor(p.cashOnHand * scale))
      p.startingCash = p.cashOnHand
    end
  end
end

local function sessionInterestBands(lotCount)
  lotCount = math.max(1, lotCount)
  local t = clamp01((lotCount - 2) / 6)
  local favLo = lerp(0.48, C.NPC_FAVORITE_INTEREST_LO, t)
  local favHi = lerp(0.62, C.NPC_FAVORITE_INTEREST_HI, t)
  if lotCount == 1 then
    favLo = 0.34
    favHi = 0.78
  end
  local nonFavMax = lerp(0.09, C.NPC_NONFAVORITE_INTEREST_MAX, t)
  local secondaryLo = 0.07 + 0.05 * t
  local secondaryHi = lerp(0.30, 0.17, t)
  return {
    favLo = favLo,
    favHi = favHi,
    nonFavMax = nonFavMax,
    secondaryLo = secondaryLo,
    secondaryHi = secondaryHi
  }
end

local function probOneFavoriteForSession(lotCount)
  if lotCount <= 2 then
    return 1
  end
  return lerp(0.76, C.NPC_FAVORITES_ONE_WEIGHT, clamp01((lotCount - 2) / 6))
end

local function isPlayerConsignmentLot(lot)
  return lot and (lot.sellerInventoryId ~= nil or lot.playerListing == true)
end

local function boostCrowdInterestOnPlayerListings(personas, lots, bands)
  if not personas or not lots or #personas < 2 then
    return
  end
  local playerLots = {}
  for idx, lot in ipairs(lots) do
    if isPlayerConsignmentLot(lot) then
      table.insert(playerLots, idx)
    end
  end
  if #playerLots < 1 then
    return
  end

  local want = math.max(
    C.PLAYER_LISTING_MIN_STRONG_BIDDERS,
    math.ceil(#personas * C.PLAYER_LISTING_STRONG_BIDDER_FRAC)
  )
  want = math.min(want, #personas)

  local order = {}
  for i = 1, #personas do
    order[i] = i
  end
  for i = #order, 2, -1 do
    local j = math.random(i)
    order[i], order[j] = order[j], order[i]
  end

  for _, lotIdx in ipairs(playerLots) do
    local lot = lots[lotIdx]
    local map = lot.npcBaseInterestByPersonaId
    if type(map) ~= 'table' then
      map = {}
      lot.npcBaseInterestByPersonaId = map
    end
    for n = 1, want do
      local persona = personas[order[n]]
      local cur = tonumber(map[persona.id]) or 0
      local boosted = bands.favLo + math.random() * (bands.favHi - bands.favLo)
      if boosted < cur then
        boosted = cur
      end
      map[persona.id] = boosted
    end
  end
end

local function assignSparseFavoriteInterests(personas, lots)
  local n = #(lots or {})
  for _, lot in ipairs(lots or {}) do
    lot.npcBaseInterestByPersonaId = {}
  end
  if n < 1 then
    return
  end

  local bands = sessionInterestBands(n)

  for _, persona in ipairs(personas) do
    if n == 1 then
      local base = bands.favLo + math.random() * (bands.favHi - bands.favLo)
      lots[1].npcBaseInterestByPersonaId[persona.id] = base
    elseif n == 2 then
      local primary = math.random(1, 2)
      local secondary = 3 - primary
      lots[primary].npcBaseInterestByPersonaId[persona.id] =
        bands.favLo + math.random() * (bands.favHi - bands.favLo)
      lots[secondary].npcBaseInterestByPersonaId[persona.id] =
        bands.secondaryLo + math.random() * (bands.secondaryHi - bands.secondaryLo)
    else
      local favCount = (math.random() < probOneFavoriteForSession(n)) and 1 or 2
      favCount = math.min(favCount, n)
      local pool = {}
      for i = 1, n do
        pool[i] = i
      end
      local favSet = {}
      for _ = 1, favCount do
        local r = math.random(1, #pool)
        local lotIdx = pool[r]
        favSet[lotIdx] = true
        table.remove(pool, r)
      end
      for idx, lot in ipairs(lots) do
        local base
        if favSet[idx] then
          base = bands.favLo + math.random() * (bands.favHi - bands.favLo)
        else
          base = math.random() * bands.nonFavMax
        end
        lot.npcBaseInterestByPersonaId[persona.id] = base
      end
    end
  end

  boostCrowdInterestOnPlayerListings(personas, lots, bands)
end

local function seedLotInterest(lot, personas)
  lot.npcLiveInterestByPersonaId = {}
  lot.npcValuationNoiseByPersonaId = {}
  lot.npcNextBidAtByPersonaId = {}
  lot.npcBidCountByPersonaId = {}
  lot.npcPersonaNamesById = lot.npcPersonaNamesById or {}
  lot.roomHeat = 0
  lot.npcLastOwnBidAtByPersonaId = {}
  lot.npcBaseInterestByPersonaId = lot.npcBaseInterestByPersonaId or {}

  for _, persona in ipairs(personas) do
    local base = lot.npcBaseInterestByPersonaId[persona.id]
    if not base then
      base = math.random() * C.NPC_NONFAVORITE_INTEREST_MAX
      lot.npcBaseInterestByPersonaId[persona.id] = base
    end
    lot.npcValuationNoiseByPersonaId[persona.id] = (math.random() * 2 - 1) * C.NPC_VALUATION_NOISE_MAX
    lot.npcLiveInterestByPersonaId[persona.id] = base
    lot.npcBidCountByPersonaId[persona.id] = 0
    lot.npcPersonaNamesById[persona.id] = persona.name
  end
end

local function computePrivateMaxBid(basePrice, noise, interest, minStep)
  local perceived = (tonumber(basePrice) or 0) * (1 + (tonumber(noise) or 0))
  local mult = lerp(C.NPC_PRIVATE_MULT_LOW, C.NPC_PRIVATE_MULT_HIGH, interest)
  return roundDown(perceived * mult, minStep or 250)
end

local function computeEffectiveMaxBid(lot, persona, interest)
  local minStep = lot.minStep or 250
  local noise = (lot.npcValuationNoiseByPersonaId and lot.npcValuationNoiseByPersonaId[persona.id]) or 0
  local privateMax = computePrivateMaxBid(lot.basePrice, noise, interest, minStep)
  local commitFrac = lerp(C.NPC_MIN_SPEND_FRAC, C.NPC_MAX_SPEND_FRAC, interest)
  local commitCap = math.floor(persona.cashOnHand * commitFrac)
  return roundDown(math.max(0, math.min(privateMax, commitCap, persona.cashOnHand)), minStep)
end

local function refreshLotNpcCaps(lot, personas)
  lot.npcMaxBidsByPersonaId = lot.npcMaxBidsByPersonaId or {}
  for _, persona in ipairs(personas) do
    local interest = (lot.npcLiveInterestByPersonaId and lot.npcLiveInterestByPersonaId[persona.id]) or 0.5
    lot.npcMaxBidsByPersonaId[persona.id] = computeEffectiveMaxBid(lot, persona, interest)
  end
end

local function chooseInitialLeader(lot, personas)
  local minStep = lot.minStep or 250
  local nextBid = (lot.currentBid or 0) + minStep
  local eligible = {}
  local strongest, strongestMax = nil, -math.huge

  for _, persona in ipairs(personas) do
    local interest = (lot.npcLiveInterestByPersonaId and lot.npcLiveInterestByPersonaId[persona.id]) or 0.5
    local cap = computeEffectiveMaxBid(lot, persona, interest)
    if cap >= nextBid then table.insert(eligible, persona) end
    if cap > strongestMax then strongest, strongestMax = persona, cap end
  end
  return #eligible > 0 and eligible[math.random(1, #eligible)] or strongest
end

local function setLotLeader(lot, persona)
  if not lot or not persona then return end
  lot.highestBidder = 'npc'
  lot.leadingNpcPersonaId = persona.id
  lot.highestBidderName = persona.name or 'NPC'
end

local function initSession(host, personas, lots)
  session.host = host
  session.active = true

  assignSparseFavoriteInterests(personas, lots)
  for _, lot in ipairs(lots) do
    seedLotInterest(lot, personas)
  end
  allocateCash(personas, lots)
  for _, lot in ipairs(lots) do
    refreshLotNpcCaps(lot, personas)
    local leader = chooseInitialLeader(lot, personas)
    if leader then setLotLeader(lot, leader) end
  end
end

local function registerLot(lot, personas, lots)
  if not lot or not personas or not session.active then
    return false
  end

  local allLots = lots or {lot}
  assignSparseFavoriteInterests(personas, allLots)
  seedLotInterest(lot, personas)
  refreshLotNpcCaps(lot, personas)

  local leader = chooseInitialLeader(lot, personas)
  if leader then
    setLotLeader(lot, leader)
  end

  return true
end

local function repriceLot(lot, newBasePrice, personas)
  if not lot or not personas then return end
  lot.basePrice = newBasePrice
  lot.conditionedBasePrice = newBasePrice

  local minStep = lot.minStep or 250
  local startBid = roundNearest(newBasePrice * (0.55 + math.random() * 0.2), 500)
  lot.currentBid = math.max(minStep, startBid)

  ensurePersonasCanContestOpening(lot, personas)
  refreshLotNpcCaps(lot, personas)
  local leader = chooseInitialLeader(lot, personas)
  if leader then
    setLotLeader(lot, leader)
  else
    lot.highestBidder = 'npc'
    lot.leadingNpcPersonaId = nil
    lot.highestBidderName = 'NPC'
  end
end

local function scheduleNpcBid(lot, persona, now)
  local interest = (lot.npcLiveInterestByPersonaId and lot.npcLiveInterestByPersonaId[persona.id]) or 0.5
  local minDelay = lerp(C.NPC_SCHED_MIN_LOW, C.NPC_SCHED_MIN_HIGH, interest)
  local maxDelay = lerp(C.NPC_SCHED_MAX_LOW, C.NPC_SCHED_MAX_HIGH, interest)
  local delay = minDelay + math.random() * (maxDelay - minDelay)
  delay = delay * lerp(1.0, C.TIME_PRESSURE_MIN_DELAY_MULT, timePressure01(lot, now))
  lot.npcNextBidAtByPersonaId[persona.id] = now + math.max(C.NPC_SCHED_DELAY_FLOOR, delay)
end

local function onLotBiddingBegin(lot, now, personas)
  if not lot or not personas then return end
  lot.roomHeat = 0
  lot.npcLastOwnBidAtByPersonaId = {}
  lot.npcTimePressureGainByPersonaId = {}
  lot.initialLotDurationSec = math.max(C.TIME_PRESSURE_MIN_WINDOW, (tonumber(lot.endTime) or now) - now)

  ensurePersonasCanContestOpening(lot, personas)

  for _, persona in ipairs(personas) do
    local baseInterest = (lot.npcBaseInterestByPersonaId and lot.npcBaseInterestByPersonaId[persona.id]) or 0.5
    lot.npcLiveInterestByPersonaId[persona.id] = clamp01(baseInterest + persona.moodTilt * C.NPC_MOOD_INFLUENCE_ON_BASE)
    lot.npcBidCountByPersonaId[persona.id] = 0
    lot.npcTimePressureGainByPersonaId[persona.id] = 0
    lot.npcNextBidAtByPersonaId[persona.id] = now + C.NPC_SCHED_DELAY_FLOOR + 1.0 + math.random() * 4.0
  end
  refreshLotNpcCaps(lot, personas)
end

local function onPlayerBid(lot, incrementAmount)
  if not lot then return end
  applyBidHeatFromIncrement(lot, incrementAmount)
end

local function chooseIncrement(persona, interest, currentBid, cap, pressure, lot)
  local room = cap - currentBid
  if room < 250 then return nil end
  local affordable = {}
  for _, inc in ipairs(C.NPC_BID_INCREMENTS) do
    if inc <= room then table.insert(affordable, inc) end
  end
  if #affordable == 0 then return nil end

  local refPrice = math.max(currentBid, lot.basePrice or 0, 1500)
  local p = clamp01(pressure)
  local baseAgg = 0.34 + interest * 1.05
  local aggression = clamp(
    baseAgg * lerp(C.INCREMENT_EARLY_AGGRESSION_MULT, 1.0, p) + p * interest * C.INCREMENT_PRESSURE_AGGRESSION_BOOST,
    0.18,
    2.1
  )
  local pressureEase = clamp01(p * (0.32 + 0.68 * interest))
  local bhMult = persona.isBargainHunter and C.BARGAIN_HUNTER_BITE_PENALTY_EXP or 1.0

  local totalW, weights = 0, {}
  for _, inc in ipairs(affordable) do
    local bite = inc / refPrice
    local bitePenalty = math.exp(-C.INCREMENT_BITE_LAMBDA * bite * bhMult)
    local easedPenalty = lerp(bitePenalty, 1.0, pressureEase)
    local w = math.max(0.01, math.pow(inc / 250, aggression) * easedPenalty)
    table.insert(weights, w)
    totalW = totalW + w
  end
  local roll, acc = math.random() * totalW, 0
  for i, w in ipairs(weights) do
    acc = acc + w
    if roll <= acc then return affordable[i] end
  end
  return affordable[#affordable]
end

local function tick(lot, dtSim, personas)
  if not lot or not personas or not session.active or not session.host then return end
  local now = session.host.getAuctionTime()
  local pressure = timePressure01(lot, now)
  local nextBid = (lot.currentBid or 0) + (lot.minStep or 250)

  lot.roomHeat = clamp01((lot.roomHeat or 0) - C.ROOM_HEAT_DECAY_PER_SEC * dtSim)

  for _, persona in ipairs(personas) do
    local live = (lot.npcLiveInterestByPersonaId and lot.npcLiveInterestByPersonaId[persona.id]) or 0.5
    local heat = lot.roomHeat or 0

    if persona.isBargainHunter then
      live = live + C.INTEREST_CONTRARIAN_STRENGTH * personaContrarianLeanMultiplier(persona) * (0.5 - heat) * dtSim
    else
      live = live + C.INTEREST_FOMO_STRENGTH * personaFomoLeanMultiplier(persona) * (heat - 0.5) * dtSim
    end

    local effMax = computeEffectiveMaxBid(lot, persona, live)
    if pressure > 0 and effMax >= nextBid then
      local gained = (lot.npcTimePressureGainByPersonaId and lot.npcTimePressureGainByPersonaId[persona.id]) or 0
      local remaining = math.max(0, C.TIME_PRESSURE_INTEREST_MAX - gained)
      if remaining > 0 then
        local delta = math.min(remaining, C.TIME_PRESSURE_INTEREST_PER_SEC * pressure *
          timePressureInterestWeight(live) * dtSim)
        live = live + delta
        lot.npcTimePressureGainByPersonaId[persona.id] = gained + delta
      end
    end

    lot.npcLiveInterestByPersonaId[persona.id] = clamp01(live)
  end

  local bidsThisFrame = 0
  local dueNpcs = {}
  for _, persona in ipairs(personas) do
    local nextAt = lot.npcNextBidAtByPersonaId and lot.npcNextBidAtByPersonaId[persona.id]
    if nextAt and now >= nextAt then
      table.insert(dueNpcs, persona)
    end
  end
  table.sort(dueNpcs, function(a, b)
    return (lot.npcNextBidAtByPersonaId[a.id] or 0) < (lot.npcNextBidAtByPersonaId[b.id] or 0)
  end)

  local lastOwn = lot.npcLastOwnBidAtByPersonaId or {}
  for i, persona in ipairs(dueNpcs) do
    if bidsThisFrame >= C.MAX_BIDS_PER_FRAME then break end
    local ownLast = lastOwn[persona.id] or 0
    if now < ownLast + C.NPC_MIN_GAP_AFTER_OWN_BID then
      lot.npcNextBidAtByPersonaId[persona.id] = ownLast + C.NPC_MIN_GAP_AFTER_OWN_BID + 0.05 + math.random() * 0.35
    else
      local interest = lot.npcLiveInterestByPersonaId[persona.id] or 0.5
      local effMax = computeEffectiveMaxBid(lot, persona, interest)
      local currentBid = lot.currentBid or 0
      local minStep = lot.minStep or 250
      local isLeader = lot.highestBidder == 'npc' and lot.leadingNpcPersonaId == persona.id

      if effMax < currentBid + minStep or isLeader then
        scheduleNpcBid(lot, persona, now)
      else
        local playerLeads = lot.highestBidder == 'player'
        local headroom = clamp01((effMax - currentBid) / math.max(lot.basePrice or 1, 1))
        local baseBidChance = 0.22 + interest * 0.44 + headroom * 0.18 + (playerLeads and 0.08 or 0)
        if isPlayerConsignmentLot(lot) then
          baseBidChance = baseBidChance + C.PLAYER_LISTING_BID_CHANCE_BONUS
        end
        local bidChance = clamp(
          baseBidChance + C.TIME_PRESSURE_BID_BONUS_MAX * pressure * timePressureInterestWeight(interest),
          C.NPC_BID_CHANCE_FLOOR,
          C.NPC_BID_CHANCE_CEIL
        )

        if math.random() < bidChance then
          local inc = chooseIncrement(persona, interest, currentBid, effMax, pressure, lot)
          if inc then
            session.host.commitNpcBid(lot, persona, inc)
            bidsThisFrame = bidsThisFrame + 1
            lot.npcLastOwnBidAtByPersonaId[persona.id] = now
            applyBidHeatFromIncrement(lot, inc)
            lot.npcBidCountByPersonaId[persona.id] = (lot.npcBidCountByPersonaId[persona.id] or 0) + 1
            for j = i + 1, #dueNpcs do
              local queuedPersona = dueNpcs[j]
              if (lot.npcNextBidAtByPersonaId[queuedPersona.id] or 0) <= now then
                local stagger = C.DUE_NPC_STAGGER_MIN +
                  math.random() * (C.DUE_NPC_STAGGER_MAX - C.DUE_NPC_STAGGER_MIN)
                lot.npcNextBidAtByPersonaId[queuedPersona.id] = now + stagger
              end
            end
          end
        end
        scheduleNpcBid(lot, persona, now)
      end
    end
  end
end

local function onLotEnd(lot, personas)
  if not lot or not personas then return end

  if lot.highestBidder == 'npc' and lot.leadingNpcPersonaId then
    for _, persona in ipairs(personas) do
      if persona.id == lot.leadingNpcPersonaId then
        persona.cashOnHand = math.max(0, persona.cashOnHand - (lot.currentBid or 0))
        break
      end
    end
  end

  for _, persona in ipairs(personas) do
    persona.moodTilt = persona.moodTilt * C.NPC_MOOD_DECAY
    local bidCount = (lot.npcBidCountByPersonaId and lot.npcBidCountByPersonaId[persona.id]) or 0
    local isWinner = lot.highestBidder == 'npc' and lot.leadingNpcPersonaId == persona.id

    if isWinner then
      persona.moodTilt = persona.moodTilt + C.MOOD_DELTA_WON
    elseif bidCount > 0 then
      persona.moodTilt = persona.moodTilt + C.MOOD_DELTA_LOST_CHASE
    else
      persona.moodTilt = persona.moodTilt + C.MOOD_DELTA_SAT_OUT
    end
    persona.moodTilt = clamp(persona.moodTilt, -1, 1)
  end
end

local function resetSession()
  session.host = nil
  session.active = false
end

M.generatePersonas = generatePersonas
M.initSession = initSession
M.registerLot = registerLot
M.repriceLot = repriceLot
M.onLotBiddingBegin = onLotBiddingBegin
M.onPlayerBid = onPlayerBid
M.tick = tick
M.onLotEnd = onLotEnd
M.resetSession = resetSession
M.getNpcCountForLotCount = getNpcCountForLotCount
M.computeEffectiveMaxBid = computeEffectiveMaxBid

return M
