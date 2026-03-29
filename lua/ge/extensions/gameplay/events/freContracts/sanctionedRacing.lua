local M = {}

local freConfig = require("gameplay/fre/config")

local CONFIG_DIR = "competitiveRace"
local CONFIG_RACE_FILENAME = "aiRacingConfig.json"
local DISCIPLINE_ROAD = "roadracing"

local DEFAULT_PODIUM_MULT = { first = 8, second = 4.5, third = 2.5 }
local DEFAULT_PODIUM_VARIANCE = { min = 0.84, max = 1.16 }
local PLACE_JITTER = { min = 0.92, max = 1.08 }

-- Loopable sanctioned offers: max laps ≈ how many target-time laps fit in 10 minutes; roll min..max; scale payouts vs design lapCount in race_data.
local SANCTIONED_MAX_WINDOW_SEC = 600
local SANCTIONED_LAP_ROLL_CAP = 60
local SANCTIONED_MIN_LAP_COUNT = 2
local SANCTIONED_PODIUM_XP_OF_MONEY = 0.1

local function moneyToSanctionedXp(m)
  return math.max(0, math.floor((tonumber(m) or 0) * SANCTIONED_PODIUM_XP_OF_MONEY + 1e-9))
end

-- Baseline money (race reward at target time) is multiplied by branch before podium place multipliers.
local DEFAULT_CLASS_PAYOUT_MULT = {
  stock = 1,
  modified = 1.35,
  super = 1.85,
  open = 2.35,
}

-- Sub-brackets per stock/modified/super (vehiclePool bands). One is chosen at random (weighted) per offer.
local DEFAULT_SANCTIONED_HP_BRACKETS = {
  { branch = "stock", id = "stock_low", label = "Stock (low)", classHpMin = 80, classHpMax = 200, pickWeight = 1 },
  { branch = "stock", id = "stock_mid", label = "Stock (mid)", classHpMin = 150, classHpMax = 280, pickWeight = 1 },
  { branch = "stock", id = "stock_high", label = "Stock (high)", classHpMin = 220, classHpMax = 319, pickWeight = 1 },
  { branch = "modified", id = "modified_low", label = "Modified (low)", classHpMin = 320, classHpMax = 400, pickWeight = 1 },
  { branch = "modified", id = "modified_mid", label = "Modified (mid)", classHpMin = 380, classHpMax = 480, pickWeight = 1 },
  { branch = "modified", id = "modified_high", label = "Modified (high)", classHpMin = 420, classHpMax = 549, pickWeight = 1 },
  { branch = "super", id = "super_low", label = "Super (low)", classHpMin = 550, classHpMax = 600, pickWeight = 1 },
  { branch = "super", id = "super_mid", label = "Super (mid)", classHpMin = 580, classHpMax = 650, pickWeight = 1 },
  { branch = "super", id = "super_high", label = "Super (high)", classHpMin = 610, classHpMax = 699, pickWeight = 1 },
}

local cachedLevelId = nil
local cachedCfg = nil
local runtime = {
  suppressFrePayouts = false,
  podiumEligible = false,
  dispatchUiActive = false,
}

local mCelebrationRewards = nil

local function defaultCfgSlice()
  return {
    variants = {},
    sanctionedRaceNames = {},
    defaultOfferRefreshMinutes = 20,
    defaultStartDeadlineMinutes = 60,
  }
end

local function normalizeRouteType(rt)
  if type(rt) ~= "string" then
    return "main"
  end
  if string.lower(rt) == "alt" then
    return "alt"
  end
  return "main"
end

local function readRaceRewardInputs(levelId, raceName, routeType)
  if type(levelId) ~= "string" or levelId == "" or type(raceName) ~= "string" or raceName == "" then
    return nil
  end
  local data = jsonReadFile("levels/" .. levelId .. "/race_data.json")
  if type(data) ~= "table" then
    return nil
  end
  local race = (data.races or {})[raceName]
  if type(race) ~= "table" then
    return nil
  end
  local goalTime, baseReward
  if normalizeRouteType(routeType) == "alt" and type(race.altRoute) == "table" then
    goalTime = tonumber(race.altRoute.bestTime)
    baseReward = tonumber(race.altRoute.reward)
  else
    goalTime = tonumber(race.bestTime)
    baseReward = tonumber(race.reward)
  end
  if not goalTime or goalTime <= 0 or not baseReward or baseReward <= 0 then
    return nil
  end
  return goalTime, baseReward, race
end

local function getRaceRewardAtTargetTime(levelId, raceName, routeType)
  local goalTime, baseReward, race = readRaceRewardInputs(levelId, raceName, routeType)
  if not goalTime then
    return nil
  end
  local u = gameplay_events_freeroam_utils
  if not u or not u.raceReward then
    return nil
  end
  return u.raceReward(goalTime, baseReward, goalTime, race.type)
end

local function getRaceLapCount(levelId, raceName, routeType)
  if type(levelId) ~= "string" or levelId == "" or type(raceName) ~= "string" or raceName == "" then
    return nil
  end
  local data = jsonReadFile("levels/" .. levelId .. "/race_data.json")
  if type(data) ~= "table" then
    return nil
  end
  local race = (data.races or {})[raceName]
  if type(race) ~= "table" then
    return nil
  end
  local r = race
  if normalizeRouteType(routeType) == "alt" and type(race.altRoute) == "table" then
    r = race.altRoute
  end
  local lc = tonumber(r.lapCount)
  if lc and lc > 0 then
    return math.floor(lc)
  end
  return nil
end

local function getRaceBestTimeSeconds(levelId, raceName, routeType)
  if type(levelId) ~= "string" or levelId == "" or type(raceName) ~= "string" or raceName == "" then
    return nil
  end
  local data = jsonReadFile("levels/" .. levelId .. "/race_data.json")
  if type(data) ~= "table" then
    return nil
  end
  local race = (data.races or {})[raceName]
  if type(race) ~= "table" then
    return nil
  end
  if normalizeRouteType(routeType) == "alt" and type(race.altRoute) == "table" then
    local t = tonumber(race.altRoute.bestTime)
    return (t and t > 0) and t or nil
  end
  local t = tonumber(race.bestTime)
  return (t and t > 0) and t or nil
end

local function getDisciplineIdsFromRace(race)
  local disciplineIds = {}
  local seen = {}
  if type(race) ~= "table" then
    return disciplineIds
  end
  for _, rawType in ipairs(race.type or {}) do
    local disciplineId = freConfig.getDisciplineIdFromType(rawType)
    if disciplineId and not seen[disciplineId] then
      seen[disciplineId] = true
      table.insert(disciplineIds, disciplineId)
    end
  end
  return disciplineIds
end

local function getClassPayoutMultiplier(branch, overrides)
  local key = type(branch) == "string" and string.lower(branch) or ""
  local tab = type(overrides) == "table" and overrides or nil
  if tab and tab[key] ~= nil then
    local v = tonumber(tab[key])
    if v and v > 0 then
      return v
    end
  end
  local d = DEFAULT_CLASS_PAYOUT_MULT[key]
  if type(d) == "number" and d > 0 then
    return d
  end
  return 1
end

local function podiumMultFromTable(t, key, defaultVal)
  local tab = type(t) == "table" and t or {}
  local v = tonumber(tab[key])
  if v == nil then
    return defaultVal
  end
  return math.max(0, v)
end

local function computePodiumPayouts(baseMoney, variant)
  local helpers = gameplay_events_freContracts_helpers
  local pm = variant.podiumMultipliers
  local m1 = podiumMultFromTable(pm, "first", DEFAULT_PODIUM_MULT.first)
  local m2 = podiumMultFromTable(pm, "second", DEFAULT_PODIUM_MULT.second)
  local m3 = podiumMultFromTable(pm, "third", DEFAULT_PODIUM_MULT.third)
  local pv = variant.podiumVariance
  local vmin = math.max(0.1, tonumber(pv and pv.min) or DEFAULT_PODIUM_VARIANCE.min)
  local vmax = math.max(vmin, tonumber(pv and pv.max) or DEFAULT_PODIUM_VARIANCE.max)
  local bundle = helpers.randomFloat(vmin, vmax)
  local function placePayout(mult)
    local j = helpers.randomFloat(PLACE_JITTER.min, PLACE_JITTER.max)
    return math.max(0, math.floor(baseMoney * mult * bundle * j + 0.5))
  end
  local p1 = placePayout(m1)
  local p2 = placePayout(m2)
  local p3 = placePayout(m3)
  return p1, p2, p3
end

local function normalizeHpBrackets(list)
  local out = {}
  if type(list) ~= "table" then
    return out
  end
  for _, b in ipairs(list) do
    if type(b) == "table" then
      local lo = math.floor(tonumber(b.classHpMin) or 0)
      local hi = math.floor(tonumber(b.classHpMax) or lo)
      if hi < lo then
        lo, hi = hi, lo
      end
      local w = tonumber(b.pickWeight)
      if w == nil then
        w = 1
      end
      w = math.max(0, w)
      if w > 0 and hi >= lo then
        table.insert(out, {
          branch = type(b.branch) == "string" and b.branch or nil,
          id = type(b.id) == "string" and b.id or nil,
          label = type(b.label) == "string" and b.label or nil,
          classHpMin = lo,
          classHpMax = hi,
          pickWeight = w,
        })
      end
    end
  end
  return out
end

local function pickWeightedFromList(entries)
  local helpers = gameplay_events_freContracts_helpers
  local total = 0
  for _, v in ipairs(entries) do
    total = total + (tonumber(v.pickWeight) or 0)
  end
  if total <= 0 then
    return nil
  end
  local roll = helpers.randomFloat(0, total)
  local running = 0
  for _, v in ipairs(entries) do
    running = running + (tonumber(v.pickWeight) or 0)
    if roll < running then
      return v
    end
  end
  return entries[#entries]
end

local function collectSanctionedVariants(raw, disciplineId)
  local list = {}
  if type(raw) ~= "table" or type(raw.byRace) ~= "table" then
    return list
  end
  local wantDisc = string.lower(tostring(disciplineId or ""))
  for pathKey, entry in pairs(raw.byRace) do
    if type(pathKey) == "string" and type(entry) == "table" then
      local s = entry.sanctioned
      if type(s) == "table" and s.enabled ~= false then
        local sd = string.lower(tostring(s.disciplineId or DISCIPLINE_ROAD))
        if sd == wantDisc then
          local w = tonumber(s.pickWeight)
          if w == nil then
            w = 1
          end
          w = math.max(0, w)
          local rn = type(s.raceName) == "string" and s.raceName ~= "" and s.raceName or nil
          if w > 0 and rn then
            table.insert(list, {
              pathKey = pathKey,
              raceName = rn,
              routeType = normalizeRouteType(s.routeType),
              pickWeight = w,
              stageNumber = tonumber(s.stageNumber) or nil,
              hpBrackets = type(s.hpBrackets) == "table" and s.hpBrackets or nil,
              podiumMultipliers = type(s.podiumMultipliers) == "table" and s.podiumMultipliers or nil,
              podiumVariance = type(s.podiumVariance) == "table" and s.podiumVariance or nil,
              classPayoutMultipliers = type(s.classPayoutMultipliers) == "table" and s.classPayoutMultipliers or nil,
              offerRefreshMinutes = s.offerRefreshMinutes,
              startDeadlineMinutes = s.startDeadlineMinutes,
            })
          end
        end
      end
    end
  end
  return list
end

local function pickWeightedVariant(variants)
  return pickWeightedFromList(variants)
end

local function loadCfg()
  local levelId = gameplay_events_freContracts_state.getCurrentLevelId() or ""
  if cachedLevelId == levelId and cachedCfg then
    return cachedCfg
  end
  cachedLevelId = levelId
  cachedCfg = defaultCfgSlice()
  if levelId == "" then
    return cachedCfg
  end
  local path = "levels/" .. levelId .. "/" .. CONFIG_DIR .. "/" .. CONFIG_RACE_FILENAME
  local raw = jsonReadFile(path)
  if type(raw) ~= "table" then
    return cachedCfg
  end
  cachedCfg.variants = collectSanctionedVariants(raw, DISCIPLINE_ROAD)
  cachedCfg.sanctionedRaceNames = {}
  for _, v in ipairs(cachedCfg.variants) do
    if type(v.raceName) == "string" and v.raceName ~= "" then
      cachedCfg.sanctionedRaceNames[v.raceName] = true
    end
  end
  if #cachedCfg.variants > 0 then
    local v0 = cachedCfg.variants[1]
    cachedCfg.defaultOfferRefreshMinutes =
      math.max(0.25, tonumber(v0.offerRefreshMinutes) or cachedCfg.defaultOfferRefreshMinutes)
    cachedCfg.defaultStartDeadlineMinutes =
      math.max(1, tonumber(v0.startDeadlineMinutes) or cachedCfg.defaultStartDeadlineMinutes)
  end
  return cachedCfg
end

local function isSanctionedRaceNameConfigured(raceName)
  if type(raceName) ~= "string" or raceName == "" then
    return false
  end
  local cfg = loadCfg()
  local s = cfg.sanctionedRaceNames
  return type(s) == "table" and s[raceName] == true
end

local function hasSanctionedForRoadRacing()
  return #loadCfg().variants > 0
end

local function rollOfferForDiscipline(disciplineId, now)
  local cfg = loadCfg()
  local variants = cfg.variants
  if #variants == 0 then
    return nil
  end
  local variant = pickWeightedVariant(variants)
  if not variant then
    return nil
  end
  local rCache = gameplay_events_freContracts_raceCache
  local raceEntry = rCache.findRaceEntry(disciplineId, variant.raceName, variant.routeType, nil)
  if not raceEntry then
    raceEntry = rCache.findRaceEntry(disciplineId, variant.raceName, "main", nil)
  end
  if not raceEntry then
    return nil
  end
  local levelId = gameplay_events_freContracts_state.getCurrentLevelId() or ""
  local goalTime, rawTabularReward, raceRow = readRaceRewardInputs(levelId, variant.raceName, variant.routeType)
  if not goalTime then
    return nil
  end
  local uFre = gameplay_events_freeroam_utils
  if not uFre or not uFre.raceReward then
    return nil
  end
  local baseMoney = uFre.raceReward(goalTime, rawTabularReward, goalTime, raceRow.type)
  if not baseMoney or baseMoney <= 0 then
    return nil
  end
  local bracketSrc = variant.hpBrackets
  if type(bracketSrc) ~= "table" or #bracketSrc == 0 then
    bracketSrc = DEFAULT_SANCTIONED_HP_BRACKETS
  end
  local brackets = normalizeHpBrackets(bracketSrc)
  if #brackets == 0 then
    return nil
  end
  local br = pickWeightedFromList(brackets)
  if not br then
    return nil
  end
  local refMin = br.classHpMin
  local refMax = br.classHpMax
  local classPayMult = getClassPayoutMultiplier(br.branch, variant.classPayoutMultipliers)
  local helpers = gameplay_events_freContracts_helpers
  local refLaps = getRaceLapCount(levelId, variant.raceName, variant.routeType) or 3
  local bestTime = getRaceBestTimeSeconds(levelId, variant.raceName, variant.routeType)
  local lapCount = refLaps
  local lapScale = 1
  if type(bestTime) == "number" and bestTime > 0 and helpers and helpers.randomInt then
    local maxLaps = math.floor(SANCTIONED_MAX_WINDOW_SEC / bestTime)
    maxLaps = math.max(SANCTIONED_MIN_LAP_COUNT, math.min(maxLaps, SANCTIONED_LAP_ROLL_CAP))
    lapCount = helpers.randomInt(SANCTIONED_MIN_LAP_COUNT, maxLaps)
    lapScale = lapCount / refLaps
  end
  if lapCount < SANCTIONED_MIN_LAP_COUNT then
    lapCount = SANCTIONED_MIN_LAP_COUNT
    lapScale = lapCount / refLaps
  end
  -- Economy + difficulty cash scaling: only via gameplay_events_freeroam_utils.race_reward (economy adjuster + job market;
  -- difficulty preset syncs adjuster in career_modules_difficultyMode.applyEconomyPreset). No second reward mult here.
  local preClassLapMoney = baseMoney * classPayMult * lapScale
  local freSkillSponsorMoneyMult = 1
  if gameplay_events_freContracts_race and gameplay_events_freContracts_race.calculateRewardModifiers then
    local mods = gameplay_events_freContracts_race.calculateRewardModifiers(getDisciplineIdsFromRace(raceRow))
    if type(mods) == "table" then
      freSkillSponsorMoneyMult = tonumber(mods.moneyMultiplier) or 1
    end
  end
  local prePodiumMoney = preClassLapMoney * freSkillSponsorMoneyMult
  local scaledBase = prePodiumMoney
  local p1, p2, p3 = computePodiumPayouts(scaledBase, variant)
  local xp1, xp2, xp3 = moneyToSanctionedXp(p1), moneyToSanctionedXp(p2), moneyToSanctionedXp(p3)
  local refresh = math.max(0.25, tonumber(variant.offerRefreshMinutes) or cfg.defaultOfferRefreshMinutes)
  local deadline = math.max(1, tonumber(variant.startDeadlineMinutes) or cfg.defaultStartDeadlineMinutes)
  local stageNum = tonumber(variant.stageNumber)
  if stageNum == nil or stageNum < 1 then
    stageNum = 1
  end
  stageNum = math.floor(stageNum)
  return {
    id = gameplay_events_freContracts_state.nextId("fre-sanctioned"),
    disciplineId = disciplineId,
    raceName = raceEntry.raceName,
    raceLabel = raceEntry.raceLabel,
    stageNumber = stageNum,
    raceRouteType = raceEntry.routeType or variant.routeType,
    sanctionedPathKey = variant.pathKey,
    hpBracketId = br.id,
    hpBracketBranch = br.branch,
    hpBracketLabel = br.label,
    hpBracketPayoutMult = classPayMult,
    classHpMin = refMin,
    classHpMax = refMax,
    lapCount = lapCount,
    payoutFirst = p1,
    payoutSecond = p2,
    payoutThird = p3,
    xpFirst = xp1,
    xpSecond = xp2,
    xpThird = xp3,
    phase = "available",
    createdAt = now,
    visibleExpiresAt = now + refresh,
    startDeadlineMinutes = deadline,
    committedAt = nil,
    startDeadlineAt = nil,
  }
end

local function ensureSrState(state)
  if not state.sanctionedRacing or type(state.sanctionedRacing) ~= "table" then
    state.sanctionedRacing = { offer = nil, nextGenAt = 0 }
  end
  local sr = state.sanctionedRacing
  if sr.offer ~= nil and type(sr.offer) ~= "table" then
    sr.offer = nil
  end
  sr.nextGenAt = tonumber(sr.nextGenAt) or 0
  return sr
end

local function skillOk(disciplineId)
  local need = freConfig.getSanctionedRacingUnlockLevel()
  return gameplay_events_freContracts_skills.getSkillLevel(disciplineId) >= need
end

function M.syncGeneration(now)
  if not gameplay_events_freContracts_state.isCareerActive() then
    return false
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local changed = false
  local n = tonumber(now) or state.simTime or 0

  if not skillOk(DISCIPLINE_ROAD) then
    sr.lastSkillGateOk = false
    if sr.offer then
      sr.offer = nil
      sr.nextGenAt = 0
      changed = true
    end
    return changed
  end

  if not hasSanctionedForRoadRacing() then
    if sr.offer then
      sr.offer = nil
      sr.nextGenAt = 0
      changed = true
    end
    return changed
  end

  do
    local prev = sr.lastSkillGateOk
    if prev == nil then
      prev = true
    end
    local justUnlocked = (prev == false)
    sr.lastSkillGateOk = true
    if justUnlocked and not sr.offer then
      local newOffer = rollOfferForDiscipline(DISCIPLINE_ROAD, n)
      if newOffer then
        sr.offer = newOffer
        sr.nextGenAt = newOffer.visibleExpiresAt
      else
        sr.nextGenAt = n + 0.5
      end
      changed = true
    end
  end

  local offer = sr.offer
  if offer and offer.phase == "committed" and (tonumber(offer.startDeadlineAt) or 0) > 0 and n >= offer.startDeadlineAt then
    sr.offer = nil
    local cfgDl = loadCfg()
    sr.nextGenAt = n + math.max(0.5, tonumber(cfgDl.defaultOfferRefreshMinutes) or 12)
    changed = true
    offer = nil
  end

  if offer and offer.phase == "available" and n >= (tonumber(offer.visibleExpiresAt) or 0) then
    local newOffer = rollOfferForDiscipline(DISCIPLINE_ROAD, n)
    if newOffer then
      sr.offer = newOffer
      sr.nextGenAt = newOffer.visibleExpiresAt
    else
      sr.offer = nil
      sr.nextGenAt = n + 0.5
    end
    changed = true
    offer = sr.offer
  end

  if not sr.offer and n >= (tonumber(sr.nextGenAt) or 0) then
    local cfg = loadCfg()
    local newOffer = rollOfferForDiscipline(DISCIPLINE_ROAD, n)
    if newOffer then
      sr.offer = newOffer
      sr.nextGenAt = newOffer.visibleExpiresAt
    else
      sr.nextGenAt = n + math.max(1, tonumber(cfg.defaultOfferRefreshMinutes) or 12)
    end
    changed = true
  end

  return changed
end

local function getCompetitiveTrackFlow()
  local c = gameplay_events_freeroam_competitiveTrackFlow
  if c then
    return c
  end
  if extensions and extensions["gameplay_events_freeroam_competitiveTrackFlow"] then
    return extensions["gameplay_events_freeroam_competitiveTrackFlow"]
  end
  return nil
end

function M.getOfferUiSnapshot(now)
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local n = tonumber(now) or state.simTime or 0
  local offer = sr.offer
  if not offer then
    return nil
  end
  local useAlt = string.lower(tostring(offer.raceRouteType or "main")) == "alt"
  local dispatchActive = false
  if offer.phase == "committed" then
    if runtime.dispatchUiActive == true then
      dispatchActive = true
    end
    local ctf = getCompetitiveTrackFlow()
    if ctf and ctf.isSanctionedCareerGoToRaceActive and ctf.isSanctionedCareerGoToRaceActive() then
      dispatchActive = true
    end
  end
  return {
    id = offer.id,
    disciplineId = offer.disciplineId,
    raceName = offer.raceName,
    raceLabel = offer.raceLabel,
    stageNumber = tonumber(offer.stageNumber) or 1,
    raceRouteType = offer.raceRouteType,
    useAltRoute = useAlt,
    hpBracketId = offer.hpBracketId,
    hpBracketBranch = offer.hpBracketBranch,
    hpBracketLabel = offer.hpBracketLabel,
    hpBracketPayoutMult = offer.hpBracketPayoutMult,
    classHpMin = offer.classHpMin,
    classHpMax = offer.classHpMax,
    lapCount = tonumber(offer.lapCount) or 3,
    payoutFirst = offer.payoutFirst,
    payoutSecond = offer.payoutSecond,
    payoutThird = offer.payoutThird,
    xpFirst = offer.xpFirst,
    xpSecond = offer.xpSecond,
    xpThird = offer.xpThird,
    phase = offer.phase,
    minutesUntilRefresh = math.max(0, (tonumber(offer.visibleExpiresAt) or n) - n),
    minutesUntilStartDeadline = (offer.phase == "committed" and offer.startDeadlineAt) and
      math.max(0, offer.startDeadlineAt - n) or nil,
    dispatchActive = dispatchActive,
  }
end

function M.isSanctionedRescheduleActionActive()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return false
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o or o.phase ~= "committed" then
    return false
  end
  if runtime.dispatchUiActive == true then
    return true
  end
  local ctf = getCompetitiveTrackFlow()
  if ctf and ctf.isSanctionedCareerGoToRaceActive and ctf.isSanctionedCareerGoToRaceActive() then
    return true
  end
  return false
end

function M.isSanctionedRaceDispatchActive()
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  return o and (o.phase == "committed" or o.phase == "racing") or false
end

local function poolRefHpFromOffer(offer)
  if not offer then return nil end
  local hi = tonumber(offer.classHpMax)
  if type(hi) ~= "number" or hi <= 0 then
    return nil
  end
  return hi
end

local function pushDispatchForOffer(offer)
  if not offer then return end
  local fe = gameplay_events_freeroamEvents
  if fe and fe.startSanctionedRaceDispatch then
    fe.startSanctionedRaceDispatch(string.lower(tostring(offer.raceRouteType or "main")) == "alt", poolRefHpFromOffer(offer))
  end
end

local function validateSanctionedOfferAvailable(offer)
  if not offer or offer.phase ~= "available" then
    return false, "No open offer to commit to."
  end
  if type(offer.raceName) ~= "string" or not isSanctionedRaceNameConfigured(offer.raceName) then
    return false, "Unsupported sanctioned race."
  end
  return true, nil
end

function M.commitSanctionedRace()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return false, "Career not active."
  end
  if not skillOk(DISCIPLINE_ROAD) then
    return false, "Road Racing level too low."
  end
  if not hasSanctionedForRoadRacing() then
    return false, "No sanctioned racing on this map."
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local offer = sr.offer
  local ok, err = validateSanctionedOfferAvailable(offer)
  if not ok then
    return false, err
  end
  local n = state.simTime or 0
  local cfg = loadCfg()
  local deadlineMin = math.max(1, tonumber(offer.startDeadlineMinutes) or tonumber(cfg.defaultStartDeadlineMinutes) or 60)
  offer.phase = "committed"
  offer.committedAt = n
  offer.startDeadlineAt = n + deadlineMin
  runtime.dispatchUiActive = false
  gameplay_events_freContracts_state.refreshMaintenanceSchedule(n)
  gameplay_events_freContracts_ui.emitUiStateUpdate("sanctioned_commit")
  career_saveSystem.saveCurrent()
  return true, nil
end

function M.navigateSanctionedRace()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return false, "Career not active."
  end
  if not skillOk(DISCIPLINE_ROAD) then
    return false, "Road Racing level too low."
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local offer = sr.offer
  if not offer or (offer.phase ~= "committed" and offer.phase ~= "racing") then
    return false, "Commit to a race first."
  end
  if type(offer.raceName) ~= "string" or not isSanctionedRaceNameConfigured(offer.raceName) then
    return false, "Unsupported sanctioned race."
  end
  pushDispatchForOffer(offer)
  runtime.dispatchUiActive = true
  gameplay_events_freContracts_ui.emitUiStateUpdate("sanctioned_navigate")
  return true, nil
end

function M.rescheduleSanctionedRace()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return false, "Career not active."
  end
  if not skillOk(DISCIPLINE_ROAD) then
    return false, "Road Racing level too low."
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local offer = sr.offer
  if not offer or type(offer.raceName) ~= "string" or not isSanctionedRaceNameConfigured(offer.raceName) then
    return false, "No sanctioned race."
  end
  if offer.phase == "racing" then
    return false, "Finish or abort the race first."
  end
  if offer.phase ~= "committed" then
    return false, "Commit to a race first."
  end
  local ctf = gameplay_events_freeroam_competitiveTrackFlow
  if ctf then
    if ctf.clearSanctionedParkingStagingUi then
      ctf.clearSanctionedParkingStagingUi()
    end
    if ctf.cancelCompetitiveGridFlow then
      ctf.cancelCompetitiveGridFlow()
    end
    if ctf.leaveTrackFlowAfterRace then
      ctf.leaveTrackFlowAfterRace()
    end
  end
  local aiRacers = gameplay_events_freeroam_aiRacers
  if aiRacers and aiRacers.clearSpawned then
    aiRacers.clearSpawned()
  end
  local fe = gameplay_events_freeroamEvents
  if fe and fe.clearSanctionedDispatchStaging then
    fe.clearSanctionedDispatchStaging()
  end
  runtime.dispatchUiActive = false
  gameplay_events_freContracts_ui.emitUiStateUpdate("sanctioned_reschedule")
  return true, nil
end

function M.onRaceBegin(raceName)
  if not isSanctionedRaceNameConfigured(raceName) then
    return
  end
  local ctf = gameplay_events_freeroam_competitiveTrackFlow
  if not ctf or not ctf.isSanctionedCareerGoToRaceActive or not ctf.isSanctionedCareerGoToRaceActive() then
    return
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local offer = sr.offer
  if not offer or (offer.phase ~= "committed" and offer.phase ~= "racing") then
    return
  end
  if offer.raceName ~= raceName then
    return
  end
  offer.phase = "racing"
  runtime.dispatchUiActive = false
  runtime.suppressFrePayouts = true
  runtime.podiumEligible = true
  -- Class cap / podium: only disqualify on a trusted live HP sample (staging refresh or spawn read).
  -- Stale sync getVehicleDetails can read high incorrectly; fail open if no fresh live sample.
  local hMax = tonumber(offer.classHpMax)
  if hMax and hMax > 0 and career_modules_competitiveRace_aiRacers and career_modules_competitiveRace_aiRacers.getPlayerVehiclePowerForPodiumCapCheck then
    local hpLive = career_modules_competitiveRace_aiRacers.getPlayerVehiclePowerForPodiumCapCheck()
    if type(hpLive) == "number" and hpLive > hMax then
      runtime.podiumEligible = false
    end
  end
end

function M.shouldSuppressFrePayouts()
  return runtime.suppressFrePayouts == true
end

function M.isPodiumEligible()
  return runtime.podiumEligible == true
end

function M.clearRuntime()
  runtime.suppressFrePayouts = false
  runtime.podiumEligible = false
  runtime.dispatchUiActive = false
end

local function payPodium(place)
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local offer = sr.offer
  if not offer then
    return
  end
  local amount = 0
  local xpStored = nil
  if place == 1 then
    amount = tonumber(offer.payoutFirst) or 0
    xpStored = offer.xpFirst
  elseif place == 2 then
    amount = tonumber(offer.payoutSecond) or 0
    xpStored = offer.xpSecond
  elseif place == 3 then
    amount = tonumber(offer.payoutThird) or 0
    xpStored = offer.xpThird
  end
  local xpNum = tonumber(xpStored)
  local xpAmount = (xpNum ~= nil) and math.max(0, math.floor(xpNum)) or moneyToSanctionedXp(amount)
  if amount <= 0 or not career_modules_payment or not career_modules_payment.reward then
    mCelebrationRewards = { money = 0, noRewardDetail = "No payout configured for this podium position." }
    M.finishOfferClear()
    return
  end
  local rewardData = {
    money = { amount = amount, canBeNegative = false }
  }
  local skillKey = freConfig.getSkillKey(DISCIPLINE_ROAD)
  local grantedXp = 0
  if skillKey and xpAmount > 0 then
    rewardData[skillKey] = { amount = xpAmount }
    grantedXp = xpAmount
  end
  mCelebrationRewards = { money = math.floor(amount), disciplineXp = grantedXp }
  career_modules_payment.reward(rewardData, {
    label = string.format("Sanctioned race — P%d", place),
    tags = { "gameplay", "reward", "fre", "sanctioned_race" }
  }, true)
  M.finishOfferClear()
end

function M.finishOfferClear()
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  sr.offer = nil
  local now = state.simTime or 0
  local cfg = loadCfg()
  sr.nextGenAt = now + math.max(0.5, tonumber(cfg.defaultOfferRefreshMinutes) or 12)
  M.clearRuntime()
  gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
  career_saveSystem.saveCurrent()
  gameplay_events_freContracts_ui.emitUiStateUpdate("sanctioned_race_end")
end

function M.settleFromAiResults(aiResults, raceName)
  if not runtime.suppressFrePayouts then
    local state = gameplay_events_freContracts_state.getState()
    local sr = ensureSrState(state)
    local o = sr.offer
    local rn = raceName or (o and o.raceName)
    if rn and isSanctionedRaceNameConfigured(rn) and o and type(o.raceName) == "string" and o.raceName == rn
        and (o.phase == "committed" or o.phase == "racing") then
      M.finishOfferClear()
    end
    return
  end
  mCelebrationRewards = nil
  if not aiResults then
    mCelebrationRewards = { money = 0, noRewardDetail = "No race results — no podium reward." }
    M.finishOfferClear()
    return
  end
  local place = nil
  for _, row in ipairs(aiResults) do
    if row.isPlayer then
      place = tonumber(row.place)
      break
    end
  end
  if not place then
    mCelebrationRewards = { money = 0, noRewardDetail = "Couldn't determine placement — no podium reward." }
    M.finishOfferClear()
    return
  end
  if place >= 1 and place <= 3 then
    if not runtime.podiumEligible then
      mCelebrationRewards = { money = 0, noRewardDetail = "Over power limit — no podium rewards." }
      M.finishOfferClear()
      return
    end
    payPodium(place)
  else
    mCelebrationRewards = { money = 0, noRewardDetail = "Didn't place on the podium — no podium rewards." }
    M.finishOfferClear()
  end
end

function M.onRaceAborted()
  mCelebrationRewards = nil
  if not gameplay_events_freContracts_state.isCareerActive() then
    return
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o and not runtime.suppressFrePayouts then
    return
  end
  if runtime.suppressFrePayouts or (o and o.phase == "racing") then
    M.finishOfferClear()
  end
end

function M.onCareerTrackStagingExitAbandoned()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if o and type(o.raceName) == "string" and isSanctionedRaceNameConfigured(o.raceName) then
    M.finishOfferClear()
  end
end

function M.isRacingUnlocked(disciplineId)
  if string.lower(tostring(disciplineId or "")) ~= DISCIPLINE_ROAD then
    return false
  end
  return skillOk(DISCIPLINE_ROAD)
end

function M.isSanctionedCircuitRaceActive()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return false
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  return o and o.phase == "racing" and type(o.raceName) == "string" and isSanctionedRaceNameConfigured(o.raceName)
end

function M.isSanctionedCircuitRaceUseAltRoute()
  if not M.isSanctionedCircuitRaceActive() then
    return false
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o then
    return false
  end
  return string.lower(tostring(o.raceRouteType or "main")) == "alt"
end

function M.getAiPoolReferenceHp()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return nil
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o or type(o.raceName) ~= "string" or not isSanctionedRaceNameConfigured(o.raceName) then
    return nil
  end
  if o.phase ~= "committed" and o.phase ~= "racing" then
    return nil
  end
  local hi = tonumber(o.classHpMax)
  if not hi or hi <= 0 then
    return nil
  end
  return hi
end

-- For AI spawn fallback when player HP cannot be read: bracket limits + branch (same phase guards as getAiPoolReferenceHp).
function M.getAiSpawnSanctionedContext()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return nil
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o or type(o.raceName) ~= "string" or not isSanctionedRaceNameConfigured(o.raceName) then
    return nil
  end
  if o.phase ~= "committed" and o.phase ~= "racing" then
    return nil
  end
  local lo = tonumber(o.classHpMin)
  local hi = tonumber(o.classHpMax)
  if not hi or hi <= 0 then
    return nil
  end
  if not lo or lo < 0 then
    lo = 0
  end
  local branch = o.hpBracketBranch
  if type(branch) ~= "string" or branch == "" then
    branch = nil
  end
  return {
    classHpMin = lo,
    classHpMax = hi,
    hpBracketBranch = branch,
  }
end

function M.getSanctionedOfferLapCount()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return nil
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o or type(o.raceName) ~= "string" or not isSanctionedRaceNameConfigured(o.raceName) then
    return nil
  end
  if o.phase ~= "committed" and o.phase ~= "racing" and o.phase ~= "available" then
    return nil
  end
  local n = tonumber(o.lapCount)
  if n and n > 0 then
    return math.floor(n)
  end
  return nil
end

M.loadCfg = loadCfg
M.isSanctionedRaceNameConfigured = isSanctionedRaceNameConfigured

function M.consumeSanctionedCelebrationRewards()
  local r = mCelebrationRewards
  mCelebrationRewards = nil
  return r
end

function M.getOfferGenerationPeriodMinutes()
  local cfg = loadCfg()
  if not cfg or type(cfg.variants) ~= "table" or #cfg.variants == 0 then
    return nil
  end
  return math.max(0.25, tonumber(cfg.defaultOfferRefreshMinutes) or 12)
end

return M
