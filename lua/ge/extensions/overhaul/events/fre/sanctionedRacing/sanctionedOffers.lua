-- Sanctioned offer configuration, podium rewards, brackets and generation.
-- Read the per-load configuration/projection helpers, offer rolls, generation ticks and returned services.
local lib = {}

function lib.create(ownerServices)
  local raceDataCatalog = require("overhaul/lib/events/raceDataCatalog")
  local circuitConfig = require("overhaul/lib/events/circuitConfig")
  local helpers = require("overhaul/events/fre/helpers")
  local M = ownerServices.M

  local cachedLevelId = nil
  local cachedCfg = nil

  local function defaultCfgSlice()
    return {
      variants = {},
      sanctionedRaceNames = {},
      defaultOfferRefreshMinutes = 20,
      defaultStartDeadlineMinutes = 60,
    }
  end

  local function normalizeRouteType(racingTeam)
    if type(racingTeam) ~= "string" then return "main" end
    if string.lower(racingTeam) == "alt" then return "alt" end
    return "main"
  end

  local function getRaceDataTable(levelId)
    local rCache = overhaul_events_fre_raceCache
    if rCache and rCache.getRawRaceData then
      local data = rCache.getRawRaceData(levelId)
      if type(data) == "table" then return data end
    end
    if type(levelId) ~= "string" or levelId == "" then return nil end
    local data = raceDataCatalog.read("levels/" .. levelId .. "/race_data.json")
    return type(data) == "table" and data or nil
  end

  local function readRaceRewardInputs(levelId, raceName, routeType)
    if type(levelId) ~= "string" or levelId == "" or type(raceName) ~= "string" or raceName == "" then return nil end
    local data = getRaceDataTable(levelId)
    if type(data) ~= "table" then return nil end
    local race = (data.races or {})[raceName]
    if type(race) ~= "table" then return nil end
    local goalTime, baseReward
    if normalizeRouteType(routeType) == "alt" and type(race.altRoute) == "table" then
      goalTime = tonumber(race.altRoute.bestTime)
      baseReward = tonumber(race.altRoute.reward)
    else
      goalTime = tonumber(race.bestTime)
      baseReward = tonumber(race.reward)
    end
    if not goalTime or goalTime <= 0 or not baseReward or baseReward <= 0 then return nil end
    return goalTime, baseReward, race
  end

  local function getRaceRewardAtTargetTime(levelId, raceName, routeType)
    local goalTime, baseReward, race = readRaceRewardInputs(levelId, raceName, routeType)
    if not goalTime then return nil end
    local u = overhaul_events_utils
    if not u or not u.raceReward then return nil end
    return u.raceReward(goalTime, baseReward, goalTime, race.type)
  end

  local function getRaceLapCount(levelId, raceName, routeType)
    if type(levelId) ~= "string" or levelId == "" or type(raceName) ~= "string" or raceName == "" then return nil end
    local data = getRaceDataTable(levelId)
    if type(data) ~= "table" then return nil end
    local race = (data.races or {})[raceName]
    if type(race) ~= "table" then return nil end
    local r = race
    if normalizeRouteType(routeType) == "alt" and type(race.altRoute) == "table" then r = race.altRoute end
    local lc = tonumber(r.lapCount)
    if lc and lc > 0 then return math.floor(lc) end
    return nil
  end

  local function getRaceBestTimeSeconds(levelId, raceName, routeType)
    if type(levelId) ~= "string" or levelId == "" or type(raceName) ~= "string" or raceName == "" then return nil end
    local data = getRaceDataTable(levelId)
    if type(data) ~= "table" then return nil end
    local race = (data.races or {})[raceName]
    if type(race) ~= "table" then return nil end
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
    if type(race) ~= "table" then return disciplineIds end
    for _, rawType in ipairs(race.type or {}) do
      local disciplineId = ownerServices.freConfig.getDisciplineIdFromType(rawType)
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
      if v and v > 0 then return v end
    end
    local d = ownerServices.DEFAULT_CLASS_PAYOUT_MULT[key]
    if type(d) == "number" and d > 0 then return d end
    return 1
  end

  local function podiumMultFromTable(t, key, defaultVal)
    local tab = type(t) == "table" and t or {}
    local v = tonumber(tab[key])
    if v == nil then return defaultVal end
    return math.max(0, v)
  end

  local function computePodiumPayouts(baseMoney, variant)
    local pm = variant.podiumMultipliers
    local m1 = podiumMultFromTable(pm, "first", ownerServices.DEFAULT_PODIUM_MULT.first)
    local m2 = podiumMultFromTable(pm, "second", ownerServices.DEFAULT_PODIUM_MULT.second)
    local m3 = podiumMultFromTable(pm, "third", ownerServices.DEFAULT_PODIUM_MULT.third)
    local pv = variant.podiumVariance
    local vmin = math.max(0.1, tonumber(pv and pv.min) or ownerServices.DEFAULT_PODIUM_VARIANCE.min)
    local vmax = math.max(vmin, tonumber(pv and pv.max) or ownerServices.DEFAULT_PODIUM_VARIANCE.max)
    local bundle = helpers.randomFloat(vmin, vmax)
    local function placePayout(mult)
      local j = helpers.randomFloat(ownerServices.PLACE_JITTER.min, ownerServices.PLACE_JITTER.max)
      return math.max(0, math.floor(baseMoney * mult * bundle * j + 0.5))
    end
    local p1 = placePayout(m1)
    local p2 = placePayout(m2)
    local p3 = placePayout(m3)
    return p1, p2, p3
  end

  local function roundPw4(x)
    local n = tonumber(x)
    if not n then return 0 end
    return math.floor(n * 10000 + 0.5) / 10000
  end

  --- hp/kg brackets: classPwMin / classPwMax (aiRacingConfig hpBrackets uses same keys).
  local function normalizeSanctionedPwBrackets(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, b in ipairs(list) do
      if type(b) == "table" then
        local lo = roundPw4(b.classPwMin)
        local hi = roundPw4(b.classPwMax)
        if hi < lo then
          lo, hi = hi, lo
        end
        local w = tonumber(b.pickWeight)
        if w == nil then w = 1 end
        w = math.max(0, w)
        if w > 0 and hi >= lo then
          table.insert(out, {
            branch = type(b.branch) == "string" and b.branch or nil,
            id = type(b.id) == "string" and b.id or nil,
            label = type(b.label) == "string" and b.label or nil,
            classPwMin = lo,
            classPwMax = hi,
            pickWeight = w,
          })
        end
      end
    end
    return out
  end

  local function pickWeightedFromList(entries)
    local total = 0
    for _, v in ipairs(entries) do
      total = total + (tonumber(v.pickWeight) or 0)
    end
    if total <= 0 then return nil end
    local roll = helpers.randomFloat(0, total)
    local running = 0
    for _, v in ipairs(entries) do
      running = running + (tonumber(v.pickWeight) or 0)
      if roll < running then return v end
    end
    return entries[#entries]
  end

  local function collectSanctionedVariants(raw, disciplineId)
    local list = {}
    if type(raw) ~= "table" or type(raw.byRace) ~= "table" then return list end
    local wantDisc = string.lower(tostring(disciplineId or ""))
    local function addVariant(key, entry, routeType)
      local eventState = entry.sanctioned
      if entry.enabled == false or type(eventState) ~= "table" or eventState.enabled == false then return end
      local sd = string.lower(tostring(eventState.disciplineId or ownerServices.DISCIPLINE_ROAD))
      local weight = math.max(0, tonumber(eventState.pickWeight) or 1)
      local raceName = eventState.raceName or key
      if sd ~= wantDisc or weight == 0 or type(raceName) ~= "string" or raceName == "" then return end
      list[#list + 1] = {
        pathKey = key, raceName = raceName, routeType = normalizeRouteType(eventState.routeType or routeType),
        pickWeight = weight, stageNumber = tonumber(eventState.stageNumber),
        hpBrackets = eventState.hpBrackets, podiumMultipliers = eventState.podiumMultipliers,
        podiumVariance = eventState.podiumVariance, classPayoutMultipliers = eventState.classPayoutMultipliers,
        offerRefreshMinutes = eventState.offerRefreshMinutes, startDeadlineMinutes = eventState.startDeadlineMinutes,
      }
    end
    for key, entry in pairs(raw.byRace) do
      if type(key) == "string" and type(entry) == "table" then
        addVariant(key, entry, "main")
        for routeType, route in pairs(type(entry.routes) == "table" and entry.routes or {}) do
          if type(route) == "table" and type(route.sanctioned) == "table" then
            local merged = {}
            for k, v in pairs(entry) do merged[k] = v end
            for k, v in pairs(route) do merged[k] = v end
            addVariant(key, merged, routeType)
          end
        end
      end
    end
    table.sort(list, function(a, b)
      if a.raceName == b.raceName then return a.routeType < b.routeType end
      return a.raceName < b.raceName
    end)
    return list
  end

  local function pickWeightedVariant(variants)
    return pickWeightedFromList(variants)
  end

  local function filterVariantsByRouteBucket(variants, routeBucket)
    if type(variants) ~= "table" or #variants == 0 then return variants end
    local bucket = type(routeBucket) == "string" and string.lower(routeBucket) or ""
    local routeType = cachedCfg and cachedCfg.routeBuckets and cachedCfg.routeBuckets[bucket] or bucket
    if routeType ~= "main" and routeType ~= "alt" then return variants end
    local filtered = {}
    for _, variant in ipairs(variants) do
      if normalizeRouteType(variant.routeType) == routeType then filtered[#filtered + 1] = variant end
    end
    if #filtered > 0 then return filtered end
    return variants
  end

  --- options.bracketPick: "fleet_pw" | "above_fleet_pw" (needs options.pwReference); default weighted random.
  local function pickBracketForRollOptions(brackets, options)
    if type(brackets) ~= "table" or #brackets == 0 then return nil end
    local pick = type(options) == "table" and options.bracketPick or nil
    local pw = type(options) == "table" and tonumber(options.pwReference) or nil
    if pick == "fleet_pw" and pw and pw > 0 then
      local matches = {}
      for _, b in ipairs(brackets) do
        local lo = tonumber(b.classPwMin) or 0
        local hi = tonumber(b.classPwMax) or lo
        if pw >= lo and pw <= hi then table.insert(matches, b) end
      end
      if #matches > 0 then
        table.sort(matches, function(a, b)
          return (tonumber(a.classPwMin) or 0) > (tonumber(b.classPwMin) or 0)
        end)
        return matches[1]
      end
      local best, bestLo = nil, -1e9
      for _, b in ipairs(brackets) do
        local lo = tonumber(b.classPwMin) or 0
        local hi = tonumber(b.classPwMax) or lo
        if pw <= hi and lo > bestLo then
          bestLo = lo
          best = b
        end
      end
      if best then return best end
    elseif pick == "above_fleet_pw" and pw and pw > 0 then
      local best, bestLo = nil, 1e9
      for _, b in ipairs(brackets) do
        local lo = tonumber(b.classPwMin) or 0
        if lo > pw and lo < bestLo then
          bestLo = lo
          best = b
        end
      end
      if best then return best end
      local top = brackets[1]
      for _, b in ipairs(brackets) do
        if (tonumber(b.classPwMin) or 0) > (tonumber(top.classPwMin) or 0) then top = b end
      end
      return top
    end
    return pickWeightedFromList(brackets)
  end

  local function loadCfgForLevel(levelId)
    levelId = type(levelId) == "string" and levelId or ""
    if cachedLevelId == levelId and cachedCfg then return cachedCfg end
    cachedLevelId = levelId
    cachedCfg = defaultCfgSlice()
    if levelId == "" then return cachedCfg end
    local path = "levels/" .. levelId .. "/" .. ownerServices.CONFIG_DIR .. "/" .. ownerServices.CONFIG_RACE_FILENAME
    local raw = jsonReadFile(path)
    if type(raw) ~= "table" then return cachedCfg end
    cachedCfg.routeBuckets = type(raw.routeBuckets) == "table" and raw.routeBuckets or {}
    local definitions = circuitConfig.loadRaceDefinitions(levelId)
    for _, variant in ipairs(collectSanctionedVariants(raw, ownerServices.DISCIPLINE_ROAD)) do
      local definition = definitions[variant.raceName]
      local useAlt = variant.routeType == "alt"
      local staging = circuitConfig.stagingForRace(definition, useAlt)
      if definition and definition.competitive and circuitConfig.routeForRace(definition, useAlt)
        and circuitConfig.loadStaging(staging, levelId) then
        cachedCfg.variants[#cachedCfg.variants + 1] = variant
      else
        log("W", "sanctionedRacing", "Sanctioned race unavailable: " .. tostring(variant.raceName))
      end
    end
    cachedCfg.sanctionedRaceNames = {}
    for _, v in ipairs(cachedCfg.variants) do
      if type(v.raceName) == "string" and v.raceName ~= "" then cachedCfg.sanctionedRaceNames[v.raceName] = true end
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

  local function loadCfg()
    return loadCfgForLevel(overhaul_events_fre_state.getCurrentLevelId() or "")
  end

  local function isSanctionedRaceNameConfigured(raceName)
    if type(raceName) ~= "string" or raceName == "" then return false end
    local cfg = loadCfg()
    local eventState = cfg.sanctionedRaceNames
    return type(eventState) == "table" and eventState[raceName] == true
  end

  local function hasSanctionedForRoadRacing()
    return #loadCfg().variants > 0
  end

  --- options.branchFilter: e.g. "stock" — only HP brackets with that branch (after normalize).
  local function sanctionedBracketsForVariant(variant, options)
    local bracketSrc = variant.hpBrackets
    if type(bracketSrc) ~= "table" or #bracketSrc == 0 then
      bracketSrc = ownerServices.DEFAULT_SANCTIONED_PW_BRACKETS
    end
    local brackets = normalizeSanctionedPwBrackets(bracketSrc)
    if type(options) == "table" and type(options.branchFilter) == "string" and options.branchFilter ~= "" then
      local bf = string.lower(options.branchFilter)
      local filtered = {}
      for _, b in ipairs(brackets) do
        if string.lower(tostring(b.branch or "")) == bf then table.insert(filtered, b) end
      end
      if #filtered > 0 then brackets = filtered end
    end
    return brackets
  end

  local function sanctionedLapCountAndScale(levelId, variant)
    local refLaps = getRaceLapCount(levelId, variant.raceName, variant.routeType) or 3
    local bestTime = getRaceBestTimeSeconds(levelId, variant.raceName, variant.routeType)
    local lapCount = refLaps
    local lapScale = 1
    if type(bestTime) == "number" and bestTime > 0 and helpers and helpers.randomInt then
      local maxLaps = math.floor(ownerServices.SANCTIONED_MAX_WINDOW_SEC / bestTime)
      maxLaps = math.max(
        ownerServices.SANCTIONED_MIN_LAP_COUNT, math.min(maxLaps, ownerServices.SANCTIONED_LAP_ROLL_CAP)
      )
      lapCount = helpers.randomInt(ownerServices.SANCTIONED_MIN_LAP_COUNT, maxLaps)
      lapScale = lapCount / refLaps
    end
    if lapCount < ownerServices.SANCTIONED_MIN_LAP_COUNT then
      lapCount = ownerServices.SANCTIONED_MIN_LAP_COUNT
      lapScale = lapCount / refLaps
    end
    return lapCount, lapScale
  end

  local function sanctionedPodiumRewardAmounts(baseMoney, classPayMult, lapScale, raceRow, variant)
    -- The reward policy already includes economy/difficulty scaling; do not scale it again.
    local preClassLapMoney = baseMoney * classPayMult * lapScale
    local freSkillSponsorMoneyMult = 1
    if overhaul_events_fre_race and overhaul_events_fre_race.calculateRewardModifiers then
      local mods = overhaul_events_fre_race.calculateRewardModifiers(getDisciplineIdsFromRace(raceRow))
      if type(mods) == "table" then freSkillSponsorMoneyMult = tonumber(mods.moneyMultiplier) or 1 end
    end
    local prePodiumMoney = preClassLapMoney * freSkillSponsorMoneyMult
    local scaledBase = prePodiumMoney
    local p1, p2, p3 = computePodiumPayouts(scaledBase, variant)
    local xp1, xp2, xp3 =
      ownerServices.moneyToSanctionedXp(p1), ownerServices.moneyToSanctionedXp(p2), ownerServices.moneyToSanctionedXp(p3)
    return p1, p2, p3, xp1, xp2, xp3
  end

  local function rollOfferForVariantAtLevel(levelId, variant, disciplineId, now, allocOfferId, options)
    if type(allocOfferId) ~= "function" or type(variant) ~= "table" then return nil end
    levelId = type(levelId) == "string" and levelId or ""
    local cfg = loadCfgForLevel(levelId)
    local rCache = overhaul_events_fre_raceCache
    local raceEntry = rCache.findRaceEntry(disciplineId, variant.raceName, variant.routeType, nil)
    if not raceEntry then raceEntry = rCache.findRaceEntry(disciplineId, variant.raceName, "main", nil) end
    if not raceEntry then return nil end
    local goalTime, rawTabularReward, raceRow = readRaceRewardInputs(levelId, variant.raceName, variant.routeType)
    if not goalTime then return nil end
    local uFre = overhaul_events_utils
    if not uFre or not uFre.raceReward then return nil end
    local baseMoney = uFre.raceReward(goalTime, rawTabularReward, goalTime, raceRow.type)
    if not baseMoney or baseMoney <= 0 then return nil end
    local brackets = sanctionedBracketsForVariant(variant, options)
    if #brackets == 0 then return nil end
    local bracket = pickBracketForRollOptions(brackets, options)
    if not bracket then return nil end
    local refMin = bracket.classPwMin
    local refMax = bracket.classPwMax
    local classPayMult = getClassPayoutMultiplier(bracket.branch, variant.classPayoutMultipliers)
    local lapCount, lapScale = sanctionedLapCountAndScale(levelId, variant)
    local p1, p2, p3, xp1, xp2, xp3 = sanctionedPodiumRewardAmounts(baseMoney, classPayMult, lapScale, raceRow, variant)
    local refresh = math.max(0.25, tonumber(variant.offerRefreshMinutes) or cfg.defaultOfferRefreshMinutes)
    local deadline = math.max(1, tonumber(variant.startDeadlineMinutes) or cfg.defaultStartDeadlineMinutes)
    local stageNum = tonumber(variant.stageNumber)
    if stageNum == nil or stageNum < 1 then stageNum = 1 end
    stageNum = math.floor(stageNum)
    return {
      id = allocOfferId(),
      disciplineId = disciplineId,
      raceName = raceEntry.raceName,
      raceLabel = raceEntry.raceLabel,
      stageNumber = stageNum,
      raceRouteType = raceEntry.routeType or variant.routeType,
      sanctionedPathKey = variant.pathKey,
      hpBracketId = bracket.id,
      hpBracketBranch = bracket.branch,
      hpBracketLabel = bracket.label,
      hpBracketPayoutMult = classPayMult,
      classPwMin = refMin,
      classPwMax = refMax,
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

  local function rollOfferForDisciplineAtLevel(levelId, disciplineId, now, allocOfferId, options)
    if type(allocOfferId) ~= "function" then return nil end
    levelId = type(levelId) == "string" and levelId or ""
    local cfg = loadCfgForLevel(levelId)
    local variants = cfg.variants
    if #variants == 0 then return nil end
    if type(options) == "table" and options.routeBucket then
      variants = filterVariantsByRouteBucket(variants, options.routeBucket)
    end
    local variant = pickWeightedVariant(variants)
    if not variant then return nil end
    return rollOfferForVariantAtLevel(levelId, variant, disciplineId, now, allocOfferId, options)
  end

  local function rollOfferForDiscipline(disciplineId, now)
    local levelId = overhaul_events_fre_state.getCurrentLevelId() or ""
    return rollOfferForDisciplineAtLevel(levelId, disciplineId, now, function()
      return overhaul_events_fre_state.nextId("fre-sanctioned")
    end, nil)
  end

  --- Same rolling logic as phone sanctioned offers, for a specific level (e.g. racing team business computer).
  --- options: branchFilter, routeBucket (authored category or "main"|"alt"), bracketPick ("fleet_pw"|"above_fleet_pw"), pwReference (hp/kg).
  function M.rollRacingTeamSanctionedOffer(levelId, disciplineId, now, options)
    if type(levelId) ~= "string" or levelId == "" then return nil end
    local disc = type(disciplineId) == "string" and disciplineId ~= "" and disciplineId or ownerServices.DISCIPLINE_ROAD
    local n = tonumber(now)
    if not n then n = 0 end
    return rollOfferForDisciplineAtLevel(levelId, disc, n, function()
      return overhaul_events_fre_state.nextId("rt-race-offer")
    end, options)
  end

  --- Racing team league1 (tier 1): one sanctioned offer per configured track/route (deduped by raceName + routeType).
  --- branchFilter: optional "stock"|"modified"|"super"|"open" (default "stock") — match team hp/kg via getSanctionedBranchForPw.
  function M.buildRacingTeamLeague1StockOffers(levelId, now, branchFilter)
    if type(levelId) ~= "string" or levelId == "" then return {} end
    local n = tonumber(now)
    if not n then n = 0 end
    local bf = type(branchFilter) == "string" and branchFilter ~= "" and string.lower(branchFilter) or "stock"
    local cfg = loadCfgForLevel(levelId)
    local variants = cfg.variants
    if #variants == 0 then return {} end
    local seen = {}
    local out = {}
    for _, variant in ipairs(variants) do
      local key = string.lower(tostring(variant.raceName or ""))
        .. "\0"
        .. string.lower(tostring(variant.routeType or ""))
      if not seen[key] then
        seen[key] = true
        local o = rollOfferForVariantAtLevel(levelId, variant, ownerServices.DISCIPLINE_ROAD, n, function()
          return overhaul_events_fre_state.nextId("rt-race-offer")
        end, { branchFilter = bf })
        if o then table.insert(out, o) end
      end
    end
    return out
  end

  local function ensureSrState(state)
    if not state.sanctionedRacing or type(state.sanctionedRacing) ~= "table" then
      state.sanctionedRacing = { offer = nil, nextGenAt = 0 }
    end
    local sr = state.sanctionedRacing
    if sr.offer ~= nil and type(sr.offer) ~= "table" then sr.offer = nil end
    sr.nextGenAt = tonumber(sr.nextGenAt) or 0
    return sr
  end

  local function skillOk(disciplineId)
    local need = ownerServices.freConfig.getSanctionedRacingUnlockLevel()
    local level = overhaul_events_fre_skills.getSkillLevel(disciplineId)
    if level < need then return false end
    local tiers = overhaul_events_fre_skills.getUnlockedContractTiers(disciplineId, level)
    return #tiers > 0
  end

  -- Keep externally committed offers while level data is briefly unavailable.
  local function shouldPreserveTeamOfferDuringSanctionedMapSync(offer)
    if type(offer) ~= "table" then return false end
    if offer.racingTeamBusinessOffer ~= true and offer.league1PlayerRace ~= true then return false end
    local phase = offer.phase
    return phase == "committed" or phase == "racing" or phase == "available"
  end

  local function syncSanctionedSkillGate(sr)
    local changed = false
      sr.lastSkillGateOk = false
      if sr.offer and not shouldPreserveTeamOfferDuringSanctionedMapSync(sr.offer) then
        ownerServices.srTrace(
          string.format(
            "syncGeneration CLEAR (skill gate) phase=%s teamOffer=%s league1=%s",
            tostring(sr.offer.phase),
            tostring(sr.offer.racingTeamBusinessOffer == true),
            tostring(sr.offer.league1PlayerRace == true)
          )
        )
        sr.offer = nil
        sr.nextGenAt = 0
        changed = true
      end
    return changed
  end

  local function syncSanctionedEmptyMap(sr, n)
    local changed = false
      if sr.offer and not shouldPreserveTeamOfferDuringSanctionedMapSync(sr.offer) then
        ownerServices.srTrace(
          string.format(
            "syncGeneration CLEAR (no sanctioned for road) phase=%s teamOffer=%s league1=%s",
            tostring(sr.offer.phase),
            tostring(sr.offer.racingTeamBusinessOffer == true),
            tostring(sr.offer.league1PlayerRace == true)
          )
        )
        sr.offer = nil
        sr.nextGenAt = 0
        changed = true
      end
      -- Advance empty-map generation schedules so maintenance does not stay due every frame.
      if not sr.offer and n >= (tonumber(sr.nextGenAt) or 0) then
        sr.nextGenAt = n + 1
        changed = true
      end
    return changed
  end

  local function syncNewlyUnlockedSanctionedOffer(sr, n)
    local changed = false
    do
      local prev = sr.lastSkillGateOk
      if prev == nil then prev = true end
      local justUnlocked = (prev == false)
      sr.lastSkillGateOk = true
      if justUnlocked and not sr.offer then
        local newOffer = rollOfferForDiscipline(ownerServices.DISCIPLINE_ROAD, n)
        if newOffer then
          sr.offer = newOffer
          sr.nextGenAt = newOffer.visibleExpiresAt
        else
          sr.nextGenAt = n + 0.5
        end
        changed = true
      end
    end

    return changed
  end

  local function expireSanctionedCommit(sr, offer, n)
    local changed = false
    -- Team commits can remain staged, so the phone start deadline must not expire them.
    local skipCommitDeadline = offer and (offer.racingTeamBusinessOffer == true or offer.league1PlayerRace == true)
    if
      not skipCommitDeadline
      and offer
      and offer.phase == "committed"
      and (tonumber(offer.startDeadlineAt) or 0) > 0
      and n >= offer.startDeadlineAt
    then
      sr.offer = nil
      local cfgDl = loadCfg()
      sr.nextGenAt = n + math.max(0.5, tonumber(cfgDl.defaultOfferRefreshMinutes) or 12)
      changed = true
      offer = nil
    end

    return changed, offer
  end

  local function refreshSanctionedAvailability(sr, offer, n)
    local changed = false
    if offer and offer.phase == "available" and n >= (tonumber(offer.visibleExpiresAt) or 0) then
      local newOffer = rollOfferForDiscipline(ownerServices.DISCIPLINE_ROAD, n)
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
      local newOffer = rollOfferForDiscipline(ownerServices.DISCIPLINE_ROAD, n)
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

  function M.syncGeneration(now)
    if not overhaul_events_fre_state.isCareerActive() then return false end
    local state = overhaul_events_fre_state.getState()
    local sr = ensureSrState(state)
    local changed = false
    local n = tonumber(now) or state.simTime or 0

    if not skillOk(ownerServices.DISCIPLINE_ROAD) then return syncSanctionedSkillGate(sr) end
    if not hasSanctionedForRoadRacing() then return syncSanctionedEmptyMap(sr, n) end
    changed = syncNewlyUnlockedSanctionedOffer(sr, n) or changed
    local offer = sr.offer
    local deadlineChanged
    deadlineChanged, offer = expireSanctionedCommit(sr, offer, n)
    changed = deadlineChanged or changed
    changed = refreshSanctionedAvailability(sr, offer, n) or changed
    return changed
  end

  return {
    loadCfgForLevel = loadCfgForLevel,
    loadCfg = loadCfg,
    isSanctionedRaceNameConfigured = isSanctionedRaceNameConfigured,
    hasSanctionedForRoadRacing = hasSanctionedForRoadRacing,
    ensureSrState = ensureSrState,
    skillOk = skillOk,
  }
end

return lib
