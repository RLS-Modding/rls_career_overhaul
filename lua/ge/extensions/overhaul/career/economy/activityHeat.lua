-- Job demand owns episode state, transient multipliers and the unchanged career save.
-- Config and state, earning tags, demand episodes, notifications, saves, projections, update and hooks.

local M = {}

local phoneLayout = require("overhaul/lib/phone/layoutOwner")
local saveStore = require('overhaul/lib/save/store')
local ensureDir = require('overhaul/lib/save/ensureDir')
local capabilities = require('overhaul/lib/platform/capabilities')
local activityTaxonomy = require('overhaul/lib/career/activityTaxonomy')

-- Config ---------------------------------------------------------------------------------------------

local SAVE_VERSION = 3

-- Demand follows career simulation days rather than map daylight.
local SIM_SECONDS_PER_GAME_DAY = require("overhaul/lib/career/gameTime").SIM_SECONDS_PER_GAME_DAY

local TRANSIENT_FLOOR     = 0.50
local TRANSIENT_CEIL      = 2.00
local MIN_HOT_JOBS        = 3
local HOT_THRESHOLD       = 1.10    -- +10% — Market Watch "high demand"
local SURGE_DAYS_MIN      = 1.0
local SURGE_DAYS_MAX      = 3.0
local SURGE_FACTOR_MIN    = 1.12    -- +12%
local SURGE_FACTOR_MAX    = 1.40    -- +40%
local COOLDOWN_DAYS_MIN   = 0.45
local COOLDOWN_DAYS_MAX   = 1.25
local PLAYER_NIBBLE       = 1.0     -- one completion = one job of demand
local PLAYER_NIBBLE_DEBOUNCE_SEC = 2.0 -- collapse multi addAttributes on one job
local NPC_RATE_JITTER     = 0.22    -- ±% on NPC jobs/day when a surge starts

-- Notification: only when a job newly enters high demand (no cooling spam)
local NOTIF_PREF_KEY = "jobMarket"
local ADVERT_COOLDOWN_SEC = 180 -- Indeed-style marker ads, real-time seconds
local PAYOUT_NOTIF_COOLDOWN_SEC = 45

local taxonomy = activityTaxonomy.load()
local BRANCHES, JOB_LEAF_SET, LEAF_LABEL = {}, {}, {}
for _, branch in ipairs(taxonomy.branches) do
  local row = {id = branch.id, label = branch.label, leaves = {}}
  for _, leaf in ipairs(branch.leaves) do
    row.leaves[#row.leaves + 1] = {id = leaf.id, label = leaf.label}
    JOB_LEAF_SET[leaf.id] = true
    LEAF_LABEL[leaf.id] = leaf.label
  end
  BRANCHES[#BRANCHES + 1] = row
end

-- State ----------------------------------------------------------------------------------------------

local episodes = {}
local cooldownUntil = {}
local debugForce = {}
local bandNotified = {}
local lastAdvertAt = 0
local lastAdvertJob = nil
local lastPayoutNotifAt = 0
local lastPlayerNibbleAt = {} -- [leafId] = os.clock()

local simTime = 0
local tickCount = 0
local lastTickJob = nil
local loaded = false
local suspendedForChallenge = false
local pendingTransientPush = false
local suppressDemandNotifs = false
local marketDirty = false
local saveFeature = nil

-- Save registration and shared helpers ---------------------------------------------------------------

local function featureSave()
  if not saveFeature then
    saveFeature = assert(saveStore.feature('economy.activityHeat', {
      owner = 'overhaul_career_economy_activityHeat', phase = 'profile', required = true,
      files = {'career/rls_career/activityHeat.json'}, writer = {pretty = true},
    }))
  end
  return saveFeature
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function randomInRange(lo, hi)
  return lo + math.random() * (hi - lo)
end

local function shuffleInPlace(list)
  for i = #list, 2, -1 do
    local j = math.random(i)
    list[i], list[j] = list[j], list[i]
  end
  return list
end

local function careerActive()
  return overhaul_career_career.isActive()
end

local function isChallengeActive()
  return overhaul_career_challengeModes.isChallengeActive() == true
end

-- Notification preferences ---------------------------------------------------------------------------

local function notificationsEnabled()
  local layout = phoneLayout.get()
  if layout and layout.getSettings then
    local ok, s = pcall(layout.getSettings)
    if ok and type(s) == "table" and type(s.notifications) == "table" then
      return s.notifications[NOTIF_PREF_KEY] ~= false
    end
  end
  return true
end

local function canPushSurgeNotifications()
  if not notificationsEnabled() then return false end
  local policy = capabilities.get('marketOpportunityNotifications')
  return policy ~= nil and policy.canNotifyMarketOpportunity() == true
end

-- Earning tags ---------------------------------------------------------------------------------------

-- Earnings arrive from both array-tagged and dictionary-tagged payers.
local function tagsAsLookup(tags)
  if type(tags) ~= "table" then return {} end
  local out = {}
  for k, v in pairs(tags) do
    if type(k) == "number" and type(v) == "string" then
      out[v] = true
    elseif type(k) == "string" and v then
      out[k] = true
    end
  end
  if next(out) then return out end
  return tags
end

-- An unrelated earning must not drain job demand.
local function classifyEarningTags(tags)
  tags = tagsAsLookup(tags)
  local function has(t) return tags[t] == true end

  for tag in pairs(taxonomy.excludedEarningTags) do if has(tag) then return nil end end

  for _, leaf in ipairs(taxonomy.earningLeaves) do
    for _, tag in ipairs(leaf.earningTags) do
      if has(tag) then return leaf.id end
    end
  end

  return nil
end

-- Available jobs and demand factors ------------------------------------------------------------------

local function isTypeEnabled(typeName)
  return (overhaul_career_economyAdjuster.getTypeMultiplier(typeName) or 1.0) ~= 0
end

local function isLeafAvailable(leafId)
  return activityTaxonomy.available(taxonomy.byId[leafId])
end

local function isLeafUsable(leafId)
  if not isLeafAvailable(leafId) then return false end
  if not isTypeEnabled(leafId) then
    local prefix = taxonomy.byId[leafId].typeFamilyPrefix
    if prefix then
      for _, t in ipairs(overhaul_career_economyAdjuster.getAvailableTypes() or {}) do
        if (t == leafId or tostring(t):sub(1, #prefix) == prefix) and isTypeEnabled(t) then
          return true
        end
      end
    end
    return false
  end
  return true
end

local function listUsableLeaves()
  local out = {}
  for _, branch in ipairs(BRANCHES) do
    for _, leaf in ipairs(branch.leaves) do
      if isLeafUsable(leaf.id) then
        out[#out + 1] = leaf.id
      end
    end
  end
  return out
end

local function remainingFrac(episode)
  if not episode then return 0 end
  local maxPool = tonumber(episode.poolMax) or 0
  if maxPool <= 1e-6 then return 0 end
  return clamp((tonumber(episode.pool) or 0) / maxPool, 0, 1)
end

local function effectiveMult(leafId)
  if debugForce[leafId] then
    return clamp(tonumber(debugForce[leafId]) or 1.0, TRANSIENT_FLOOR, TRANSIENT_CEIL)
  end
  local episode = episodes[leafId]
  if episode and (tonumber(episode.pool) or 0) > 1e-6 then
    return clamp(tonumber(episode.factor) or 1.0, TRANSIENT_FLOOR, TRANSIENT_CEIL)
  end
  return 1.0
end

local function snapshotMults(leaves)
  local snap = {}
  for _, id in ipairs(leaves) do
    snap[id] = effectiveMult(id)
  end
  return snap
end

-- Demand notifications -------------------------------------------------------------------------------

local function fireHighDemandNotification(leafId, magnitude)
  if not canPushSurgeNotifications() then return end
  local label = LEAF_LABEL[leafId] or leafId
  local pct = math.floor(math.abs(magnitude - 1.0) * 100 + 0.5)
  guihooks.trigger("PhoneLockNotification", {
    title = string.format("%s in high demand", label),
    message = string.format("%s is paying a premium right now.", label),
    meta = string.format("+%d%% pay", pct),
    kind = "success",
    source = "Market Watch",
    category = NOTIF_PREF_KEY,
    ttl = 10,
    sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
  })
end

local function maybeShowOpportunityAdvert(source)
  if not careerActive() or not loaded then return false end
  if isChallengeActive() then return false end
  if not canPushSurgeNotifications() then return false end

  local now = os.time()
  if lastAdvertAt > 0 and (now - lastAdvertAt) < ADVERT_COOLDOWN_SEC then
    return false
  end

  local hot = {}
  for _, id in ipairs(listUsableLeaves()) do
    local m = effectiveMult(id)
    if m >= HOT_THRESHOLD then
      hot[#hot + 1] = { id = id, m = m }
    end
  end
  if #hot == 0 then return false end
  table.sort(hot, function(a, b) return a.m > b.m end)

  local pick = hot[1]
  if #hot > 1 and lastAdvertJob then
    for _, h in ipairs(hot) do
      if h.id ~= lastAdvertJob then
        pick = h
        break
      end
    end
  end

  lastAdvertAt = now
  lastAdvertJob = pick.id
  local label = LEAF_LABEL[pick.id] or pick.id
  local pct = math.floor((pick.m - 1.0) * 100 + 0.5)
  guihooks.trigger("PhoneLockNotification", {
    title = string.format("Hiring: %s", label),
    message = string.format("%s rates are up — open Market Watch → Opportunities.", label),
    meta = string.format("+%d%%", pct),
    kind = "info",
    source = "Market Watch",
    category = NOTIF_PREF_KEY,
    ttl = 8,
    sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
  })
  return true
end

local function checkBandCrossings(leafId, oldMult, newMult)
  bandNotified[leafId] = bandNotified[leafId] or {}
  local flags = bandNotified[leafId]

  if oldMult < HOT_THRESHOLD and newMult >= HOT_THRESHOLD then
    if not flags.hot then
      flags.hot = true
      if not suppressDemandNotifs then
        fireHighDemandNotification(leafId, newMult)
      end
    end
  elseif newMult < HOT_THRESHOLD then
    flags.hot = nil
  end
end

-- Market publication and multipliers -----------------------------------------------------------------

local function publishEconomyLeavesChanged(changedLeafIds)
  if #changedLeafIds == 0 then return false end
  -- A failing market subscriber must not undo the committed demand or retry a refresh.
  local ok, err = pcall(extensions.hook, "onOverhaulEconomyLeavesChanged", changedLeafIds)
  if not ok then log("E", "activityHeat", "economy-change notification failed: " .. tostring(err)) end
  return true
end

local function notifyCurrentMarket()
  local usable = listUsableLeaves()
  local changedLeafIds = {}
  for _, id in ipairs(usable) do
    changedLeafIds[#changedLeafIds + 1] = id
  end
  return publishEconomyLeavesChanged(changedLeafIds)
end

local function notifyEconomyChanges(before, after, synchronizeMarket)
  if synchronizeMarket then return notifyCurrentMarket() end
  local changedLeafIds = {}
  for id, newM in pairs(after or {}) do
    local oldM = (before and before[id]) or newM
    if math.abs((tonumber(oldM) or 1) - (tonumber(newM) or 1)) > 1e-4 then
      changedLeafIds[#changedLeafIds + 1] = id
    end
  end
  return publishEconomyLeavesChanged(changedLeafIds)
end

local function pushTransients(usable)
  usable = usable or listUsableLeaves()
  overhaul_career_economyAdjuster.clearTransientMultipliers()

  local usableSet = {}
  for _, id in ipairs(usable) do usableSet[id] = true end

  for leafId, _ in pairs(JOB_LEAF_SET) do
    if usableSet[leafId] then
      local factor = effectiveMult(leafId)
      if math.abs(factor - 1.0) > 1e-6 then
        overhaul_career_economyAdjuster.setTransientMultiplier(leafId, factor)
        local prefix = taxonomy.byId[leafId].typeFamilyPrefix
        if prefix then
          for _, t in ipairs(overhaul_career_economyAdjuster.getAvailableTypes() or {}) do
            if tostring(t):sub(1, #prefix) == prefix then
              overhaul_career_economyAdjuster.setTransientMultiplier(t, factor)
            end
          end
        end
      end
    end
  end
end

-- Surge episodes and coverage ------------------------------------------------------------------------

local function countHot(usable)
  local n = 0
  for _, id in ipairs(usable) do
    if effectiveMult(id) >= HOT_THRESHOLD then
      n = n + 1
    end
  end
  return n
end

local function endSurge(leafId, reason)
  local episode = episodes[leafId]
  if not episode then return end
  episodes[leafId] = nil
  local cdDays = randomInRange(COOLDOWN_DAYS_MIN, COOLDOWN_DAYS_MAX)
  cooldownUntil[leafId] = simTime + cdDays * SIM_SECONDS_PER_GAME_DAY
  bandNotified[leafId] = bandNotified[leafId] or {}
  bandNotified[leafId].hot = nil
  marketDirty = true
  log("I", "activityHeat", string.format("Surge ended: %s (%s) remaining=%.2f",
    tostring(leafId), tostring(reason or "empty"), tonumber(episode.pool) or 0))
end

local function startSurge(leafId, opts)
  if not leafId or not JOB_LEAF_SET[leafId] then return false end
  if not isLeafUsable(leafId) then return false end
  opts = opts or {}

  local durationDays = tonumber(opts.durationDays) or randomInRange(SURGE_DAYS_MIN, SURGE_DAYS_MAX)
  durationDays = clamp(durationDays, SURGE_DAYS_MIN, SURGE_DAYS_MAX)
  local factor = tonumber(opts.factor) or randomInRange(SURGE_FACTOR_MIN, SURGE_FACTOR_MAX)
  factor = clamp(factor, HOT_THRESHOLD, TRANSIENT_CEIL)

  local baseRate = taxonomy.byId[leafId].npcJobsPerDay
  local jitter = 1.0 + randomInRange(-NPC_RATE_JITTER, NPC_RATE_JITTER)
  local npcRate = math.max(1.2, baseRate * jitter)
  if opts.npcRate then npcRate = math.max(0.5, tonumber(opts.npcRate) or npcRate) end

  local pool = npcRate * durationDays
  if opts.pool then pool = math.max(1.0, tonumber(opts.pool) or pool) end

  episodes[leafId] = {
    factor = factor,
    pool = pool,
    poolMax = pool,
    npcRate = npcRate,
    durationDays = durationDays,
    startedAtSim = simTime,
  }
  cooldownUntil[leafId] = nil
  marketDirty = true
  return true
end

local function pickSurgeCandidates(usable, includeCooldown)
  local out = {}
  for _, id in ipairs(usable) do
    if not episodes[id] and not debugForce[id] then
      local cd = cooldownUntil[id]
      local onCooldown = cd and simTime < cd
      if includeCooldown or not onCooldown then
        out[#out + 1] = id
      end
    end
  end
  return shuffleInPlace(out)
end

local function ensureCoverage(usable)
  usable = usable or listUsableLeaves()
  local need = MIN_HOT_JOBS - countHot(usable)
  if need <= 0 then return end

  local candidates = pickSurgeCandidates(usable, false)
  if #candidates < need then
    -- Keep useful work available when every remaining candidate is cooling down.
    candidates = pickSurgeCandidates(usable, true)
  end

  for i = 1, math.min(need, #candidates) do
    startSurge(candidates[i])
  end
end

-- Market refresh -------------------------------------------------------------------------------------

local function applyMarketChanges(before, synchronizeMarket)
  local usable = listUsableLeaves()
  ensureCoverage(usable)
  pushTransients(usable)
  local after = snapshotMults(usable)
  for _, id in ipairs(usable) do
    checkBandCrossings(id, (before and before[id]) or 1.0, after[id] or 1.0)
  end
  local notified = notifyEconomyChanges(before, after, synchronizeMarket)
  marketDirty = false
  return notified
end

local function refreshMarket(synchronizeMarket)
  local usable = listUsableLeaves()
  local before = snapshotMults(usable)
  return applyMarketChanges(before, synchronizeMarket)
end

-- Demand consumption ---------------------------------------------------------------------------------

local function drainNpcDemand(dtSim)
  if dtSim <= 0 then return end
  local days = dtSim / SIM_SECONDS_PER_GAME_DAY
  local toEnd = nil
  for id, episode in pairs(episodes) do
    if not isLeafUsable(id) then
      toEnd = toEnd or {}
      toEnd[#toEnd + 1] = { id = id, reason = "unusable" }
    else
      local rate = tonumber(episode.npcRate) or 0
      episode.pool = (tonumber(episode.pool) or 0) - rate * days
      if episode.pool <= 1e-6 then
        toEnd = toEnd or {}
        toEnd[#toEnd + 1] = { id = id, reason = "npc" }
      end
    end
  end
  if toEnd then
    for _, item in ipairs(toEnd) do
      endSurge(item.id, item.reason)
    end
  end
  for id, untilT in pairs(cooldownUntil) do
    if (tonumber(untilT) or 0) <= simTime then
      cooldownUntil[id] = nil
    end
  end
  if toEnd or marketDirty then
    refreshMarket()
    tickCount = tickCount + 1
  end
end

local function nibblePlayerDemand(jobId)
  if not jobId or not JOB_LEAF_SET[jobId] then return false end
  local episode = episodes[jobId]
  if not episode then return false end

  local now = os.clock()
  local last = lastPlayerNibbleAt[jobId] or 0
  if (now - last) < PLAYER_NIBBLE_DEBOUNCE_SEC then
    return false
  end
  lastPlayerNibbleAt[jobId] = now
  lastTickJob = jobId

  episode.pool = (tonumber(episode.pool) or 0) - PLAYER_NIBBLE
  if episode.pool <= 1e-6 then
    local usable = listUsableLeaves()
    local before = snapshotMults(usable)
    endSurge(jobId, "player")
    applyMarketChanges(before)
    tickCount = tickCount + 1
    return true
  end
  return true
end

-- Persistence helpers --------------------------------------------------------------------------------

local function saveHeat(currentSavePath, writer)
  if not careerActive() then return end
  if not loaded then return end
  if not currentSavePath then return end
  ensureDir.parentOf(writer, featureSave().path(currentSavePath))
  local data = {
    version = SAVE_VERSION,
    simTime = simTime,
    episodes = deepcopy(episodes),
    cooldownUntil = deepcopy(cooldownUntil),
    bandNotified = deepcopy(bandNotified),
    tickCount = tickCount,
    lastTickJob = lastTickJob,
    lastModified = os.time(),
  }
  featureSave().write(currentSavePath, data)
end

local function loadHeat()
  episodes = {}
  cooldownUntil = {}
  bandNotified = {}
  debugForce = {}
  lastPlayerNibbleAt = {}
  tickCount = 0
  lastTickJob = nil
  simTime = 0

  local _, currentSavePath = overhaul_career_saveSystem.getCurrentSaveSlot()
  if currentSavePath then
    local data = jsonReadFile(featureSave().path(currentSavePath))
    if data and (data.version or 0) >= SAVE_VERSION then
      simTime = tonumber(data.simTime) or 0
      episodes = data.episodes or {}
      cooldownUntil = data.cooldownUntil or {}
      bandNotified = data.bandNotified or {}
      tickCount = data.tickCount or 0
      lastTickJob = data.lastTickJob
    else
      -- Older pressure saves cannot be restored as demand episodes.
      episodes = {}
      cooldownUntil = {}
      bandNotified = {}
      tickCount = 0
      lastTickJob = nil
      simTime = 0
    end
  end

  loaded = true
  pendingTransientPush = true
end

local function safeLoadHeat()
  local ok, err = pcall(loadHeat)
  if not ok then
    loaded = false
    pendingTransientPush = false
    log("E", "activityHeat", "loadHeat failed: " .. tostring(err))
  end
end

-- Market projections ---------------------------------------------------------------------------------

local function demandPolarity(factor)
  if factor > 1.001 then return "surge" end
  if factor < 0.999 then return "cooldown" end
  return "neutral"
end

local function marketLeaf(leaf, branchId, usableSet)
  local available = usableSet[leaf.id] == true
  local factor = available and effectiveMult(leaf.id) or 1.0
  local episode = episodes[leaf.id]
  return {
    key = leaf.id, label = leaf.label, branch = branchId,
    pressure = remainingFrac(episode), -- Keep the old UI field alongside remaining demand.
    factor = factor, polarity = demandPolarity(factor), available = available,
    remaining = remainingFrac(episode), durationDays = episode and episode.durationDays or nil,
  }
end

local function medianFactor(factors)
  if #factors == 0 then return 1.0 end
  table.sort(factors)
  local middle = math.ceil(#factors / 2)
  if #factors % 2 == 0 then return (factors[middle] + factors[middle + 1]) / 2 end
  return factors[middle]
end

local function marketBranch(branch, usableSet, extremes)
  local leaves, factors = {}, {}
  for _, leaf in ipairs(branch.leaves) do
    local row = marketLeaf(leaf, branch.id, usableSet)
    leaves[#leaves + 1] = row
    if row.available then
      factors[#factors + 1] = row.factor
      if not extremes.hottest or row.factor > extremes.hottest.factor then extremes.hottest = row end
      if not extremes.softest or row.factor < extremes.softest.factor then extremes.softest = row end
    end
  end
  local median = medianFactor(factors)
  return {key = branch.id, label = branch.label, factor = median,
    polarity = demandPolarity(median), available = #factors > 0, leaves = leaves}
end

local function getMarketSummary()
  local usableSet = {}
  for _, id in ipairs(listUsableLeaves()) do usableSet[id] = true end
  local branches, extremes = {}, {}
  for _, branch in ipairs(BRANCHES) do branches[#branches + 1] = marketBranch(branch, usableSet, extremes) end
  local hottest, softest = extremes.hottest, extremes.softest
  return {
    version = SAVE_VERSION, branches = branches,
    hottest = hottest and {key = hottest.key, label = hottest.label, factor = hottest.factor} or nil,
    softest = softest and {key = softest.key, label = softest.label, factor = softest.factor} or nil,
    hotThreshold = HOT_THRESHOLD, tickCount = tickCount, lastTickJob = lastTickJob,
  }
end

-- Demand readers and payout notifications ------------------------------------------------------------

local function getDemandFactorForTags(tags)
  local jobId = classifyEarningTags(tags)
  if not jobId then return nil, 1.0 end
  return jobId, effectiveMult(jobId)
end

local function getDemandFactor(leafId)
  if not leafId or not JOB_LEAF_SET[leafId] then return 1.0 end
  return effectiveMult(leafId)
end

local function formatSurgeBonusText(jobIdOrFactor)
  local factor = jobIdOrFactor
  if type(jobIdOrFactor) == "string" then
    factor = getDemandFactor(jobIdOrFactor)
  end
  factor = tonumber(factor) or 1.0
  if factor < HOT_THRESHOLD then return "" end
  return string.format(" (+%d%% High Demand)", math.floor((factor - 1) * 100 + 0.5))
end

local function notifyHighDemandPayout(jobId, money, factor)
  if not canPushSurgeNotifications() then return false end
  if isChallengeActive() then return false end
  factor = tonumber(factor) or 1.0
  money = tonumber(money) or 0
  if factor < HOT_THRESHOLD or money <= 0 then return false end

  local now = os.time()
  if lastPayoutNotifAt > 0 and (now - lastPayoutNotifAt) < PAYOUT_NOTIF_COOLDOWN_SEC then
    return false
  end

  local label = LEAF_LABEL[jobId] or jobId or "Job"
  local pct = math.floor((factor - 1.0) * 100 + 0.5)
  local bonus = money * (factor - 1.0) / factor
  if bonus < 1 then return false end

  lastPayoutNotifAt = now
  guihooks.trigger("PhoneLockNotification", {
    title = "High demand bonus",
    message = string.format("You earned about $%d extra on this %s payout.", math.floor(bonus + 0.5), label),
    meta = string.format("+%d%%", pct),
    kind = "success",
    source = "Market Watch",
    category = NOTIF_PREF_KEY,
    ttl = 6,
    sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
  })
  return true
end

local function getStateSummary()
  return {
    version = SAVE_VERSION,
    simTime = simTime,
    episodes = deepcopy(episodes),
    cooldownUntil = deepcopy(cooldownUntil),
    tickCount = tickCount,
    lastTickJob = lastTickJob,
    challengeSuspended = isChallengeActive(),
    debugForce = deepcopy(debugForce),
  }
end

-- Console demand controls ----------------------------------------------------------------------------

local function forceSurge(jobId, magnitude)
  if not jobId then return false end
  local targets = {}
  if JOB_LEAF_SET[jobId] then
    targets[1] = jobId
  else
    for _, branch in ipairs(BRANCHES) do
      if branch.id == jobId then
        for _, leaf in ipairs(branch.leaves) do
          targets[#targets + 1] = leaf.id
        end
        break
      end
    end
  end
  if #targets == 0 then
    log("I", "activityHeat", string.format("[activityHeat] Unknown job/branch '%s'", tostring(jobId)))
    return false
  end
  magnitude = clamp(tonumber(magnitude) or 1.5, TRANSIENT_FLOOR, TRANSIENT_CEIL)
  local usable = listUsableLeaves()
  local before = snapshotMults(usable)
  for _, id in ipairs(targets) do
    if isLeafAvailable(id) then
      debugForce[id] = magnitude
      if magnitude >= HOT_THRESHOLD then
        startSurge(id, { factor = magnitude, durationDays = 2.0 })
      else
        episodes[id] = nil
        debugForce[id] = magnitude
      end
    end
  end
  applyMarketChanges(before)
  log("I", "activityHeat", string.format("[activityHeat] Forced surge on '%s' x%.2f", tostring(jobId), magnitude))
  return true
end

local function clearDebugForce()
  debugForce = {}
  refreshMarket()
end

-- Console diagnostics --------------------------------------------------------------------------------
local function debugDump()
  log("I", "activityHeat", "\n=== Opportunity Economy (activityHeat) ===")
  log("I", "activityHeat", string.format("Sim days: %.2f | Events: %d | Last job: %s | Challenge: %s",
    simTime / SIM_SECONDS_PER_GAME_DAY, tickCount, tostring(lastTickJob), tostring(isChallengeActive())))
  local summary = getMarketSummary()
  for _, branch in ipairs(summary.branches or {}) do
    log("I", "activityHeat", string.format("  [%s] median %+.0f%%", branch.label, ((branch.factor or 1) - 1) * 100))
    for _, leaf in ipairs(branch.leaves or {}) do
      if leaf.available then
        local episode = episodes[leaf.key]
        if episode then
          local daysLeft = 0
          if (tonumber(episode.npcRate) or 0) > 1e-6 then
            daysLeft = (tonumber(episode.pool) or 0) / episode.npcRate
          end
          log("I", "activityHeat", string.format("    %-18s SURGE x%.2f (%+.0f%%)  pool=%.1f/%.1f  ~%.1fd left  npc/day=%.1f",
            leaf.label, leaf.factor or 1, ((leaf.factor or 1) - 1) * 100,
            tonumber(episode.pool) or 0, tonumber(episode.poolMax) or 0, daysLeft, tonumber(episode.npcRate) or 0))
        else
          local cd = cooldownUntil[leaf.key]
          local cdLeft = cd and math.max(0, (cd - simTime) / SIM_SECONDS_PER_GAME_DAY) or 0
          log("I", "activityHeat", string.format("    %-18s baseline x%.2f%s",
            leaf.label, leaf.factor or 1,
            cdLeft > 0 and string.format("  cooldown %.1fd", cdLeft) or ""))
        end
      end
    end
  end
  log("I", "activityHeat", "==========================================\n")
end

local function debugAddPressure(jobId, amount)
  if not jobId or not JOB_LEAF_SET[jobId] then return end
  local episode = episodes[jobId]
  if not episode then
    log("I", "activityHeat", string.format("[activityHeat] '%s' is not surged", tostring(jobId)))
    return
  end
  local n = tonumber(amount) or 1.0
  lastPlayerNibbleAt[jobId] = nil
  episode.pool = (tonumber(episode.pool) or 0) - n
  if episode.pool <= 1e-6 then
    local usable = listUsableLeaves()
    local before = snapshotMults(usable)
    endSurge(jobId, "debug")
    applyMarketChanges(before)
  end
end

-- Per-frame update -----------------------------------------------------------------------------------
local function onUpdate(dtReal, dtSim, dtRaw)
  if not careerActive() then return end
  if not loaded then return end

  if pendingTransientPush then
    pendingTransientPush = false
    local ok, err = pcall(function()
      suspendedForChallenge = isChallengeActive()
      if suspendedForChallenge then
        overhaul_career_economyAdjuster.clearTransientMultipliers()
      else
        suppressDemandNotifs = true
        refreshMarket(true)
      end
    end)
    suppressDemandNotifs = false
    if not ok then
      log("E", "activityHeat", "pendingTransientPush failed: " .. tostring(err))
    end
  end

  local challenge = isChallengeActive()
  if challenge ~= suspendedForChallenge then
    suspendedForChallenge = challenge
    if challenge then
      overhaul_career_economyAdjuster.clearTransientMultipliers()
    else
      refreshMarket()
    end
  end

  if suspendedForChallenge then return end

  local dt = tonumber(dtSim) or 0
  if dt <= 0 then return end
  simTime = simTime + dt
  drainNpcDemand(dt)
end

-- Career lifecycle -----------------------------------------------------------------------------------

local function onOverhaulPlayerAttributesChanged(change, reason)
  if not careerActive() or not loaded then return end
  if not change or not reason then return end
  local money = change.money
  if type(money) ~= "number" or money <= 0 then return end
  if isChallengeActive() then return end
  local jobId = classifyEarningTags(reason.tags)
  if not jobId then return end
  nibblePlayerDemand(jobId)
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  saveHeat(currentSavePath, writer)
end

local function onCareerActivated()
  safeLoadHeat()
end

local function onExtensionLoaded()
  if careerActive() then
    safeLoadHeat()
  end
end

-- Public API -----------------------------------------------------------------------------------------

M.getMarketSummary = getMarketSummary
M.getStateSummary = getStateSummary
M.getDemandFactorForTags = getDemandFactorForTags
M.getDemandFactor = getDemandFactor
M.formatSurgeBonusText = formatSurgeBonusText
M.HOT_THRESHOLD = HOT_THRESHOLD
M.notifyHighDemandPayout = notifyHighDemandPayout
M.classifyEarningTags = classifyEarningTags
M.getBranches = function() return deepcopy(BRANCHES) end
-- Console controls -----------------------------------------------------------------------------------
M.debugDump = debugDump
M.forceSurge = forceSurge
M.debugAddPressure = debugAddPressure
M.clearDebugForce = clearDebugForce
M.maybeShowOpportunityAdvert = maybeShowOpportunityAdvert
M.debugAddHeat = debugAddPressure

-- Game hooks -----------------------------------------------------------------------------------------
M.onUpdate = onUpdate
M.onOverhaulPlayerAttributesChanged = onOverhaulPlayerAttributesChanged
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onCareerActivated = onCareerActivated
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = function()
  if saveFeature then saveFeature.dispose(); saveFeature = nil end
end

return M
