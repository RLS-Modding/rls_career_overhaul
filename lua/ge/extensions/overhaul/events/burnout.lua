-- Burnout zones turn vehicle tire-wear reports into HUD state, rewards and records.
-- Read zone configuration and state, scoring/settlement, vehicle callbacks, frame updates and lifecycle.
local capabilities = require("overhaul/lib/platform/capabilities")
local freeroamUtils = require("overhaul/events/utils")
local burnoutConfig = require("overhaul/lib/events/burnoutConfig")
local resultIds = require("overhaul/lib/events/resultIdentity").create("burnout")
local M = {}

-- Config ------------------------------------------------------------------------------------------

local MAX_RUN_SECONDS = 60
local TIRE_POP_FINISH_GRACE_SECONDS = 3
local SITE_ZONE_EXIT_GRACE_SECONDS = 0.2
local COMPLETION_DISPLAY_SECONDS = 10
local XP_ATTRIBUTE_KEY = "careerSkills-mayhem"

local MIN_REWARD_SECONDS = 1

-- State ---------------------------------------------------------------------------------------------

local activeVehicles = {}
local latestSummaries = {}
local sessions = {}
local damagedVehicles = {}
local pendingStopSummaries = {}
local pendingStopReasons = {}
local lastResult = nil
local siteZoneOccupancy = { vehId = nil, zoneId = nil, exitElapsed = 0 }
local completionDismissal = nil

-- Scoring and zone lookup ---------------------------------------------------------------------------

local function escapeLuaString(value)
  return tostring(value or ""):gsub("\\", "\\\\"):gsub("'", "\\'")
end

local function isPlayerVehicle(subjectId)
  return subjectId ~= nil and subjectId == be:getPlayerVehicleID(0)
end

local function isWalking()
  return gameplay_walk and gameplay_walk.isWalking() == true
end

local function getVehicleObject(vehId)
  if not vehId then return nil end
  return getObjectByID(vehId)
end

local function formatScore(value)
  return tostring(math.floor((tonumber(value) or 0) + 0.5))
end

local function getBreakdown(summary)
  return type(summary.scoreBreakdown) == "table" and summary.scoreBreakdown or {}
end

local function calculateXp(summary)
  local score = tonumber(summary.score) or 0
  local elapsed = tonumber(summary.elapsed) or 0
  if score <= 0 or elapsed <= 0 then return 0 end
  local base = math.floor(score / 35 + 0.5)
  local durationBonus = math.floor(math.min(elapsed, MAX_RUN_SECONDS) * 1.5 + 0.5)
  local popBonus = (tonumber(summary.poppedCount) or 0) * 20
  return math.max(1, math.floor(base + durationBonus + popBonus + 0.5))
end

local function getCurrentLevel()
  local level = getCurrentLevelIdentifier()
  if level then return level end
  if getMissionFilename() ~= "" then
    return core_levels.getLevelName(getMissionFilename())
  end
  return nil
end

local function loadLevelBurnoutData(level)
  return burnoutConfig.loadLevelData(level)
end

local function loadLevelBurnoutEvents(level)
  return loadLevelBurnoutData(level).events
end

local function isPointInPolygon2D(pos, vertices)
  if not pos or type(vertices) ~= "table" or #vertices < 3 then return false end
  local inside = false
  local j = #vertices
  for i = 1, #vertices do
    local vi = vertices[i]
    local vj = vertices[j]
    local xi, yi = tonumber(vi and vi[1]), tonumber(vi and vi[2])
    local xj, yj = tonumber(vj and vj[1]), tonumber(vj and vj[2])
    if xi and yi and xj and yj and ((yi > pos.y) ~= (yj > pos.y)) then
      local edgeX = (xj - xi) * (pos.y - yi) / (yj - yi) + xi
      if pos.x < edgeX then inside = not inside end
    end
    j = i
  end
  return inside
end

local function isInsideEvent(event, data, pos)
  if type(event) ~= "table" or type(event.zoneName) ~= "string" then return false end
  local zone = data.zonesByName[event.zoneName]
  return zone and isPointInPolygon2D(pos, zone.vertices)
end

local function getSiteZoneEventAtPosition(pos, preferredZoneId, data)
  data = data or loadLevelBurnoutData(getCurrentLevel())

  if preferredZoneId then
    for _, event in ipairs(data.events) do
      if event.zoneId == preferredZoneId and isInsideEvent(event, data, pos) then return event end
    end
  end
  for _, event in ipairs(data.events) do
    if isInsideEvent(event, data, pos) then return event end
  end
  return nil
end

local function getBurnoutEventDefinition(zoneId)
  if not zoneId then return nil end
  for _, event in ipairs(loadLevelBurnoutEvents(getCurrentLevel())) do
    if event.zoneId == zoneId then return event end
  end
  return nil
end

local function getZoneIdForTrigger(triggerName)
  if type(triggerName) ~= "string" then return nil end

  for _, event in ipairs(loadLevelBurnoutEvents(getCurrentLevel())) do
    if event.triggerName == triggerName then return event.zoneId end
  end
  return nil
end

-- Session HUD and tire state ------------------------------------------------------------------------

local function getInventoryIdForVehicle(vehId)
  if not vehId or not overhaul_career_garage_inventory then return nil end
  return overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
end

local function notifyFreContractsFreeroamUi()
  if overhaul_events_fre_ui and overhaul_events_fre_ui.emitUiStateUpdate then
    overhaul_events_fre_ui.emitUiStateUpdate("freeroam_session")
  end
end

local function buildBurnoutRaceData(eventDef, zoneId)
  return burnoutConfig.raceData(eventDef)
end

local function ensureFreeroamHudEvent(zoneId)
  if not overhaul_events_host then extensions.load("overhaul_events_host") end
  if not overhaul_events_utils then extensions.load("overhaul_events_utils") end
  if not overhaul_events_session then extensions.load("overhaul_events_session") end
  if not overhaul_events_raceSession then extensions.load("overhaul_events_raceSession") end

  local sess = overhaul_events_session
  local raceHud = overhaul_events_raceSession
  local freUtils = overhaul_events_utils
  if not sess or not raceHud or not freUtils then return nil, nil, nil end

  if not sess.races then sess.races = freUtils.loadRaceData() end

  local eventDef = getBurnoutEventDefinition(zoneId)
  if not eventDef then return nil, nil, nil end

  sess.races[eventDef.eventId] = sess.races[eventDef.eventId] or buildBurnoutRaceData(eventDef, zoneId)
  return sess, raceHud, eventDef
end

local function setBurnoutHudState(sess, vehId, zoneId, summary)
  summary = type(summary) == "table" and summary or {}
  sess.burnoutCompHud = {
    vehicleId = vehId,
    zoneId = zoneId or summary.zoneId,
    elapsed = tonumber(summary.elapsed) or 0,
    score = tonumber(summary.score) or 0,
    runState = summary.runState or "staging",
  }
end

local function summaryHasExistingTireDamage(summary)
  if type(summary) ~= "table" then return false end
  return (tonumber(summary.poppedDrivenCount) or 0) > 0 or (tonumber(summary.poppedCount) or 0) > 0
end

local function setVehicleTireDamageCache(vehId, damaged)
  if not vehId then return end
  if damaged then
    damagedVehicles[vehId] = true
  else
    damagedVehicles[vehId] = nil
  end
end

local function setBurnoutStagingBanner(raceHud, session, summary)
  -- Use the live wheel summary only. A previous visit's damagedVehicles cache
  -- survives garage repairs and would otherwise keep this banner stuck.
  local damaged = summaryHasExistingTireDamage(summary)
  if session then session.tiresAlreadyDamaged = damaged end
  local ready = summary and summary.readyToStart == true
  local bannerKey = damaged and "damaged" or (ready and "ready" or "stop")
  if session and session.hudBannerKey == bannerKey then return end
  if session then session.hudBannerKey = bannerKey end
  if damaged then
    raceHud.setRaceHudBanner("Tires already damaged", "bad", 0)
  elseif ready then
    raceHud.setRaceHudBanner("Staged - go when ready", "good", 0)
  else
    raceHud.setRaceHudBanner("Stop to stage", "info", 0)
  end
end

local function startBurnoutFreHudStaging(vehId, zoneId)
  local sess, raceHud, eventDef = ensureFreeroamHudEvent(zoneId)
  if not sess or not raceHud or not eventDef then return false end
  if sess.mActiveRace and sess.mActiveRace ~= eventDef.eventId then return false end

  sess.staged = eventDef.eventId
  sess.mActiveRace = nil
  sess.timerActive = false
  sess.in_race_time = 0
  sess.invalidLap = false
  sess.lapCount = 0
  sess.checkpointsHit = 0
  sess.totalCheckpoints = 0
  sess.mCurrentRouteName = nil
  setBurnoutHudState(sess, vehId, zoneId, { runState = "staging" })

  raceHud.prepareNewRaceHudState(eventDef.eventId)
  raceHud.setStagingSubjectId(getInventoryIdForVehicle(vehId) or vehId)
  local session = sessions[vehId] or {}
  setBurnoutStagingBanner(raceHud, session, { readyToStart = false })
  sessions[vehId] = session
  raceHud.showFreeroamRaceHud()
  notifyFreContractsFreeroamUi()
  return true
end

local function startBurnoutFreHudRun(vehId, zoneId, summary)
  local sess, raceHud, eventDef = ensureFreeroamHudEvent(zoneId)
  if not sess or not raceHud or not eventDef then return false end

  sess.staged = nil
  sess.mActiveRace = eventDef.eventId
  sess.mInventoryId = getInventoryIdForVehicle(vehId) or vehId
  sess.timerActive = true
  sess.in_race_time = tonumber(summary and summary.elapsed) or 0
  sess.invalidLap = false
  sess.lapCount = 0
  sess.checkpointsHit = 0
  sess.totalCheckpoints = 0
  sess.mSplitTimes = {}
  sess.mBestLapThisRun = nil
  sess.mCurrentRouteName = nil
  setBurnoutHudState(sess, vehId, zoneId, summary)

  raceHud.setStagingSubjectId(nil)
  raceHud.setRaceHudBanner("Burnout run started", "good", 3)
  raceHud.showFreeroamRaceHud()
  raceHud.pushFreeroamRaceHudState(true)
  notifyFreContractsFreeroamUi()
  return true
end

local function updateBurnoutFreHud(vehId, summary)
  if type(summary) ~= "table" then return end

  local zoneId = summary.zoneId or activeVehicles[vehId]
  local sess, raceHud, eventDef = ensureFreeroamHudEvent(zoneId)
  if not sess or not raceHud or not eventDef then return end

  setBurnoutHudState(sess, vehId, zoneId, summary)
  if summary.runState == "active" then
    if sess.mActiveRace ~= eventDef.eventId then
      startBurnoutFreHudRun(vehId, zoneId, summary)
      return
    end
    sess.in_race_time = tonumber(summary.elapsed) or sess.in_race_time or 0
    sess.timerActive = true
  elseif sess.staged == eventDef.eventId then
    sess.timerActive = false
    setBurnoutStagingBanner(raceHud, sessions[vehId] or {}, summary)
  end

  raceHud.pushFreeroamRaceHudState(false)
end

local function hideBurnoutFreHud(vehId, zoneId, force)
  local sess, raceHud, eventDef = ensureFreeroamHudEvent(zoneId)
  if not sess or not raceHud or not eventDef then return end
  local hudState = sess.burnoutCompHud
  if not force and hudState and vehId and hudState.vehicleId ~= vehId then return end
  if sess.staged == eventDef.eventId then sess.staged = nil end
  if sess.mActiveRace == eventDef.eventId then sess.mActiveRace = nil end
  sess.timerActive = false
  sess.in_race_time = 0
  sess.burnoutCompHud = nil
  completionDismissal = nil
  raceHud.setStagingSubjectId(nil)
  raceHud.hideFreeroamRaceHud(true)
  notifyFreContractsFreeroamUi()
end

-- Completion and reward settlement ------------------------------------------------------------------

local function buildCompletionBonuses(result)
  local breakdown = getBreakdown(result)
  local bonuses = {}
  local function add(label, value, sub)
    local n = tonumber(value) or 0
    if n > 0 then table.insert(bonuses, { label = label, value = formatScore(n), sub = sub == true }) end
  end
  add("Movement", breakdown.movement)
  add("Tip-in", breakdown.tipIn)
  add("Aggression", breakdown.aggression)
  add("Wheel speed", breakdown.wheelSpeed, true)
  add("RPM", breakdown.rpm, true)
  add("Smoke", breakdown.smoke, true)
  add("Control", breakdown.control, true)
  add("Pop", breakdown.popBonus)
  if (tonumber(breakdown.penalties) or 0) > 0 then
    local impactCount = tonumber(result.impactPenaltyCount) or 0
    local penaltyLabel = "Damage penalty"
    if impactCount > 0 then
      penaltyLabel = penaltyLabel .. " (" .. impactCount .. (impactCount == 1 and " impact" or " impacts") .. ")"
    end
    table.insert(bonuses, { label = penaltyLabel, value = "-" .. formatScore(breakdown.penalties) })
  end
  return bonuses
end

local function pushBurnoutFreHudCompletion(result)
  if not result or result.invalid == true or result.score <= 0 or result.elapsed <= 0 then
    hideBurnoutFreHud(result and result.vehId, result and result.zoneId, true)
    return
  end

  local sess, raceHud, eventDef = ensureFreeroamHudEvent(result.zoneId)
  if not sess or not raceHud or not eventDef then return end

  sess.mActiveRace = eventDef.eventId
  sess.mInventoryId = result.inventoryId or getInventoryIdForVehicle(result.vehId) or result.vehId
  sess.timerActive = false
  sess.in_race_time = result.elapsed
  setBurnoutHudState(sess, result.vehId, result.zoneId, {
    runState = "finished",
    elapsed = result.elapsed,
    score = result.score,
  })

  local completionPayload = {
    headline = result.isBest and "New Best Score!" or "Run Complete",
    raceTitle = eventDef.label,
    kind = "drift",
    scoreLabel = "Score",
    invalidLap = false,
    result = {
      driftScore = math.floor((tonumber(result.score) or 0) + 0.5),
      time = result.elapsed,
    },
    previous = {
      driftScore = result.previousBestScore,
    },
    rewards = {
      money = math.floor(tonumber(result.moneyAwarded) or 0),
      disciplineXp = result.xpAwarded,
    },
    bonuses = buildCompletionBonuses(result),
  }

  raceHud.pushRaceHudCompletion(
    completionPayload,
    eventDef.eventId,
    eventDef.label,
    eventDef.label,
    result.elapsed,
    true
  )
  sess.mActiveRace = nil
  sess.staged = nil
  sess.timerActive = false
  sess.in_race_time = 0
  notifyFreContractsFreeroamUi()
  completionDismissal = {
    vehId = result.vehId,
    zoneId = result.zoneId,
    remaining = COMPLETION_DISPLAY_SECONDS,
  }
end

local function recordLeaderboardResult(result)
  if not result or result.score <= 0 or result.elapsed <= 0 then return false end
  if not overhaul_career_career or not overhaul_career_career.isActive() then return false end

  local inventoryId = getInventoryIdForVehicle(result.vehId)
  if not inventoryId then return false end

  local eventDef = getBurnoutEventDefinition(result.zoneId)
  if not eventDef then return false end

  local leaderboardManager = capabilities.get("raceRecords")
  local previousEntry = leaderboardManager.getLeaderboardEntry(inventoryId, eventDef.label) or {}
  if type(previousEntry.driftScore) == "number" then
    result.previousBestScore = math.floor(previousEntry.driftScore + 0.5)
  end

  local raceData = buildBurnoutRaceData(eventDef, result.zoneId)
  local rewardElapsed = math.max(tonumber(result.elapsed) or 0, MIN_REWARD_SECONDS)
  local performanceReward = tonumber(freeroamUtils.driftReward(raceData, rewardElapsed, result.score)) or 0

  local ok, isBest = pcall(leaderboardManager.addLeaderboardEntry, {
    inventoryId = inventoryId,
    raceName = eventDef.eventId,
    raceLabel = eventDef.label,
    time = result.elapsed,
    driftScore = result.score,
    damagePercentage = 0,
    reward = performanceReward,
  })

  result.inventoryId = inventoryId
  result.raceName = eventDef.eventId
  result.raceLabel = eventDef.label
  result.isBest = ok and isBest == true or false

  local moneyAwarded = math.floor((tonumber(performanceReward) or 0) + 0.5)
  if not result.isBest then
    moneyAwarded = math.floor(moneyAwarded / 2 + 0.5)
  else
    moneyAwarded = math.floor(moneyAwarded * 1.2 + 0.5)
  end
  result.moneyAwarded = math.max(0, moneyAwarded)
  if overhaul_events_fre_race and overhaul_events_fre_skills then
    local level = overhaul_events_fre_skills.getSkillLevel("burnout")
    result.moneyAwarded =
      math.floor(result.moneyAwarded * (1 + overhaul_events_fre_race.getLaneLevelBonus("burnout", level)) + 0.5)
  end
  return result.isBest
end

local function buildResult(vehId, summary, reason)
  summary = type(summary) == "table" and summary or {}
  local zoneId = summary.zoneId or activeVehicles[vehId]
  local score = tonumber(summary.score) or 0
  local breakdown = getBreakdown(summary)
  return {
    vehId = vehId,
    zoneId = zoneId,
    mode = summary.mode or "burnoutTest",
    reason = reason or pendingStopReasons[vehId] or "finished",
    score = score,
    elapsed = math.min(tonumber(summary.elapsed) or 0, MAX_RUN_SECONDS),
    poppedCount = tonumber(summary.poppedCount) or 0,
    maxHeat = tonumber(summary.maxHeat) or 0,
    maxWear = tonumber(summary.maxWear) or 0,
    impactPenaltyCount = tonumber(summary.impactPenaltyCount) or 0,
    scoreBreakdown = {
      smoke = tonumber(breakdown.smoke) or 0,
      wheelSpeed = tonumber(breakdown.wheelSpeed) or 0,
      rpm = tonumber(breakdown.rpm) or 0,
      aggression = tonumber(breakdown.aggression) or ((tonumber(breakdown.smoke) or 0) + (tonumber(
        breakdown.wheelSpeed
      ) or 0) + (tonumber(breakdown.rpm) or 0) + (tonumber(breakdown.control) or 0)),
      tipIn = tonumber(breakdown.tipIn) or 0,
      control = tonumber(breakdown.control) or 0,
      movement = tonumber(breakdown.movement) or 0,
      popBonus = tonumber(breakdown.popBonus) or 0,
      penalties = tonumber(breakdown.penalties) or 0,
    },
  }
end

-- One payout carries money and XP together so the wallet sees a single change. The comp can never
-- be negative, which the reason records for ledger consumers.
local function payBurnoutComp(moneyAmount, xpAmount, display)
  return overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout({
    amount = moneyAmount,
    xp = xpAmount and { [XP_ATTRIBUTE_KEY] = xpAmount } or nil,
    label = display.label,
    tags = display.tags,
    reason = { canBeNegative = false },
    fullReward = true,
  }, "activity:burnout", {vehicleRole = "player"}))
end

local function notifyBurnoutCompleted(result)
  if not result.raceName or not overhaul_events_fre_race then return end
  local payload = {
    raceId = result.raceName,
    raceName = result.raceName,
    raceLabel = result.raceLabel,
    raceRouteType = "main",
    disciplineIds = { "burnout" },
    rawTypes = { "burnout" },
    finishTime = result.elapsed,
    historyPrize = result.historyPrize or 0,
    vehicleId = result.vehId,
    vehicleModel = overhaul_events_fre_race.getCurrentVehicleModel(result.vehId),
    invalidLap = false,
    resultMetrics = { time = result.elapsed, driftScore = result.score, invalidLap = false },
    resultId = resultIds.id(resultIds.beginRun(result.raceName), "final"),
  }
  local ok, err = pcall(overhaul_events_fre_race.onFreeroamRaceCompleted, payload)
  if not ok then log("E", "burnout", "FRE completion failed: " .. tostring(err)) end
  ok, err = pcall(extensions.hook, "onRlsFreeroamRaceResultFinalized", payload)
  if not ok then log("E", "burnout", "FRE finalized hook failed: " .. tostring(err)) end
end

local function isPositiveFinite(value)
  return type(value) == "number" and value > 0 and value < math.huge
end

local function recordResult(vehId, summary)
  local reason = pendingStopReasons[vehId] or "finished"
  local result = buildResult(vehId, summary, reason)
  result.xpAwarded = 0
  if reason == "tires already damaged" then
    result.invalid = true
    result.moneyAwarded = 0
    lastResult = result
    return result
  end
  if not isPositiveFinite(result.score) or not isPositiveFinite(tonumber(summary.elapsed)) then
    result.invalid = true
    lastResult = result
    return result
  end

  result.xpAwarded = calculateXp(summary)
  recordLeaderboardResult(result)

  if overhaul_career_career and overhaul_career_career.isActive() then
    local moneyAmount = (result.moneyAwarded or 0) > 0 and result.moneyAwarded or nil
    local xpAmount = result.xpAwarded > 0 and result.xpAwarded or nil
    if (moneyAmount or xpAmount) and overhaul_career_economy_payment then
      local accepted = payBurnoutComp(moneyAmount, xpAmount, {
        label = result.isBest and "Burnout Comp — New Best!" or "Burnout Comp",
        tags = { "gameplay", "burnout", "fre", "reward" },
      })
      result.historyPrize = accepted == true and moneyAmount or 0
      if overhaul_career_saveSystem then require("overhaul/lib/save/store").request("burnout:recordResult") end
    end
  elseif result.xpAwarded > 0 and overhaul_career_economy_payment then
    payBurnoutComp(nil, result.xpAwarded, {
      label = "Burnout Comp",
      tags = { "gameplay", "burnout", "fre" },
    })
  end

  local ok, err = pcall(notifyBurnoutCompleted, result)
  if not ok then log("E", "burnout", "FRE notification failed: " .. tostring(err)) end

  lastResult = result
  guihooks.trigger("BurnoutCompResult", result)
  return result
end

-- Vehicle run lifetime ------------------------------------------------------------------------------

local function parseSummary(summary)
  if type(summary) == "table" then return summary end
  if type(summary) == "string" and summary ~= "" and type(jsonDecode) == "function" then
    local ok, decoded = pcall(jsonDecode, summary)
    if ok and type(decoded) == "table" then return decoded end
  end
  return {}
end

local function startBurnoutZoneForVehicle(vehId, zoneId)
  local vehicle = getVehicleObject(vehId)
  if not vehicle then return false end

  if not getBurnoutEventDefinition(zoneId) then
    log("W", "burnout", "Cannot start burnout: zone is not configured for the current level")
    return false
  end
  if pendingStopSummaries[vehId] and latestSummaries[vehId] then
    local result = recordResult(vehId, latestSummaries[vehId])
    pushBurnoutFreHudCompletion(result)
  end
  completionDismissal = nil
  activeVehicles[vehId] = zoneId
  latestSummaries[vehId] = nil
  sessions[vehId] = {
    zoneId = zoneId,
    state = "staging",
    enteredAt = os.clock(),
    lastAbuseElapsed = 0,
    driveTiresPoppedAt = nil,
    tiresAlreadyDamaged = false,
    hudBannerKey = nil,
  }
  pendingStopSummaries[vehId] = nil
  pendingStopReasons[vehId] = nil

  local inventoryId = getInventoryIdForVehicle(vehId)
  if inventoryId and overhaul_career_maintenance_tireSystem then
    overhaul_career_maintenance_tireSystem.setBurnoutOverride(inventoryId, true)
  end

  vehicle:queueLuaCommand(
    string.format(
      "extensions.load('overhaulBurnoutScorer'); if overhaulBurnoutScorer then overhaulBurnoutScorer.startSession({zoneId='%s', mode='burnoutTest', runState='staging', maxRunSeconds=%d}) end",
      escapeLuaString(zoneId),
      MAX_RUN_SECONDS
    )
  )

  startBurnoutFreHudStaging(vehId, zoneId)
  return true
end

local function stopBurnoutZoneForVehicle(vehId, zoneId, reason)
  local vehicle = getVehicleObject(vehId)
  if vehicle then vehicle:queueLuaCommand("if overhaulBurnoutScorer then overhaulBurnoutScorer.stopSession() end") end

  if activeVehicles[vehId] then
    pendingStopReasons[vehId] = reason
    if vehicle then
      pendingStopSummaries[vehId] = true
    else
      hideBurnoutFreHud(vehId, zoneId, true)
    end
  end

  activeVehicles[vehId] = nil
  sessions[vehId] = nil
  local inventoryId = getInventoryIdForVehicle(vehId)
  if inventoryId and overhaul_career_maintenance_tireSystem then
    overhaul_career_maintenance_tireSystem.setBurnoutOverride(inventoryId, false)
  end
  return true
end

local function shouldFinishRun(vehId, summary)
  local session = sessions[vehId]
  if not session or type(summary) ~= "table" then return nil end

  if summary.runState == "active" then
    if session.tiresAlreadyDamaged == true then return "tires already damaged" end

    local elapsed = tonumber(summary.elapsed) or 0
    if session.state ~= "active" then
      session.state = "active"
      session.lastAbuseElapsed = elapsed
    end

    if (tonumber(summary.currentAbuse) or 0) > 0.05 then session.lastAbuseElapsed = elapsed end

    if elapsed >= MAX_RUN_SECONDS then return "time limit" end

    local drivenWheelCount = tonumber(summary.drivenWheelCount) or 0
    local poppedDrivenCount = tonumber(summary.poppedDrivenCount) or 0
    if drivenWheelCount > 0 and poppedDrivenCount >= drivenWheelCount then
      damagedVehicles[vehId] = true
      session.driveTiresPoppedAt = session.driveTiresPoppedAt or elapsed
      if elapsed - session.driveTiresPoppedAt >= TIRE_POP_FINISH_GRACE_SECONDS then return "drive tires popped" end
    else
      session.driveTiresPoppedAt = nil
    end
  else
    session.state = "staging"
    session.driveTiresPoppedAt = nil
  end

  return nil
end

local function onBurnoutTireWearUpdate(vehId, summaryJson)
  vehId = tonumber(vehId)
  if not vehId then return end

  local summary = parseSummary(summaryJson)
  latestSummaries[vehId] = summary
  local session = sessions[vehId]
  local hasExistingDamage = summaryHasExistingTireDamage(summary)
  if summary.runState ~= "active" then
    setVehicleTireDamageCache(vehId, hasExistingDamage)
    if session then session.tiresAlreadyDamaged = hasExistingDamage end
  elseif hasExistingDamage then
    setVehicleTireDamageCache(vehId, true)
  end
  updateBurnoutFreHud(vehId, summary)

  if summary.active == true then
    local finishReason = shouldFinishRun(vehId, summary)
    if finishReason and activeVehicles[vehId] then
      stopBurnoutZoneForVehicle(vehId, activeVehicles[vehId], finishReason)
    end
  end

  if pendingStopSummaries[vehId] and summary.active ~= true then
    local result = recordResult(vehId, summary)
    pushBurnoutFreHudCompletion(result)
    pendingStopSummaries[vehId] = nil
    pendingStopReasons[vehId] = nil
    latestSummaries[vehId] = nil
  end
end


-- Per-frame update ----------------------------------------------------------------------------------

local function clearSiteZoneOccupancy(vehId, reason)
  if siteZoneOccupancy.vehId ~= vehId then return end
  local zoneId = siteZoneOccupancy.zoneId
  if activeVehicles[vehId] == zoneId then stopBurnoutZoneForVehicle(vehId, zoneId, reason or "left site zone") end
  siteZoneOccupancy.vehId = nil
  siteZoneOccupancy.zoneId = nil
  siteZoneOccupancy.exitElapsed = 0
end

local function updateSiteZoneOccupancy(dt)
  local vehId = be:getPlayerVehicleID(0)
  if not vehId or isWalking() then
    if siteZoneOccupancy.vehId then clearSiteZoneOccupancy(siteZoneOccupancy.vehId, "left vehicle") end
    return
  end

  if siteZoneOccupancy.vehId and siteZoneOccupancy.vehId ~= vehId then
    clearSiteZoneOccupancy(siteZoneOccupancy.vehId, "vehicle switched")
  end

  local data = loadLevelBurnoutData(getCurrentLevel())
  if not data.events[1] and not siteZoneOccupancy.vehId then return end
  local vehicle = getVehicleObject(vehId)
  local pos = vehicle and vehicle:getPosition() or nil
  if not pos then return end

  local currentZoneId = siteZoneOccupancy.vehId == vehId and siteZoneOccupancy.zoneId or nil
  local event = getSiteZoneEventAtPosition(pos, currentZoneId, data)
  local nextZoneId = event and event.zoneId or nil

  if nextZoneId == currentZoneId then
    siteZoneOccupancy.exitElapsed = 0
    return
  end

  if currentZoneId and not nextZoneId then
    siteZoneOccupancy.exitElapsed = siteZoneOccupancy.exitElapsed + math.max(0, tonumber(dt) or 0)
    if siteZoneOccupancy.exitElapsed < SITE_ZONE_EXIT_GRACE_SECONDS then return end
  end

  if currentZoneId and activeVehicles[vehId] == currentZoneId then
    stopBurnoutZoneForVehicle(vehId, currentZoneId, "left site zone")
  end

  siteZoneOccupancy.vehId = nextZoneId and vehId or nil
  siteZoneOccupancy.zoneId = nextZoneId
  siteZoneOccupancy.exitElapsed = 0

  if nextZoneId and activeVehicles[vehId] ~= nextZoneId then startBurnoutZoneForVehicle(vehId, nextZoneId) end
end

local function updateCompletionDismissal(dt)
  if not completionDismissal then return end
  completionDismissal.remaining = completionDismissal.remaining - math.max(0, tonumber(dt) or 0)
  if completionDismissal.remaining > 0 then return end

  local pending = completionDismissal
  completionDismissal = nil
  local sess = overhaul_events_session
  local hudState = sess and sess.burnoutCompHud or nil
  if
    hudState
    and hudState.runState == "finished"
    and hudState.vehicleId == pending.vehId
    and hudState.zoneId == pending.zoneId
  then
    hideBurnoutFreHud(pending.vehId, pending.zoneId, true)
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  local dt = math.max(0, tonumber(dtReal) or tonumber(dtSim) or 0)
  updateSiteZoneOccupancy(tonumber(dtSim) or dt)
  updateCompletionDismissal(dt)

  for vehId, _ in pairs(activeVehicles) do
    local summary = latestSummaries[vehId]
    if type(summary) == "table" and summary.active == true then
      local finishReason = shouldFinishRun(vehId, summary)
      if finishReason then stopBurnoutZoneForVehicle(vehId, activeVehicles[vehId], finishReason) end
    end
  end
end

-- Lifecycle and vehicle hooks -----------------------------------------------------------------------

local function onBeamNGTrigger(data)
  if type(data) ~= "table" or not data.triggerName then return end

  local zoneId = getZoneIdForTrigger(data.triggerName)
  if not zoneId then return end

  if not isPlayerVehicle(data.subjectID) or isWalking() then return end

  if data.event == "enter" then
    startBurnoutZoneForVehicle(data.subjectID, zoneId)
  elseif data.event == "exit" then
    stopBurnoutZoneForVehicle(data.subjectID, zoneId, "left zone")
  end
end

local function onVehicleSwitched(oldId, newId)
  if oldId and siteZoneOccupancy.vehId == oldId then clearSiteZoneOccupancy(oldId, "vehicle switched") end
  if oldId and oldId ~= newId and activeVehicles[oldId] then
    stopBurnoutZoneForVehicle(oldId, activeVehicles[oldId], "vehicle switched")
  end
end

local function onVehicleDestroyed(vehId)
  vehId = tonumber(vehId)
  if not vehId then return end
  damagedVehicles[vehId] = nil
  if siteZoneOccupancy.vehId == vehId then clearSiteZoneOccupancy(vehId, "vehicle destroyed") end
  if activeVehicles[vehId] then
    local inventoryId = getInventoryIdForVehicle(vehId)
    if inventoryId and overhaul_career_maintenance_tireSystem then
      overhaul_career_maintenance_tireSystem.setBurnoutOverride(inventoryId, false)
    end
    hideBurnoutFreHud(vehId, activeVehicles[vehId], true)
    activeVehicles[vehId] = nil
  end
  latestSummaries[vehId] = nil
  sessions[vehId] = nil
  pendingStopSummaries[vehId] = nil
  pendingStopReasons[vehId] = nil
end

-- Public state queries ------------------------------------------------------------------------------

local function getLastResult()
  return lastResult
end

local function getResultsState()
  return { lastResult = lastResult }
end

local function getZoneDebugState(x, y, z)
  local data = loadLevelBurnoutData(getCurrentLevel())
  local configuredEvents = {}
  for _, event in ipairs(data.events) do
    local zoneResolved = nil
    if event.zoneName then zoneResolved = data.zonesByName[event.zoneName] ~= nil end
    table.insert(configuredEvents, {
      eventId = event.eventId,
      zoneId = event.zoneId,
      zoneName = event.zoneName,
      triggerName = event.triggerName,
      zoneResolved = zoneResolved,
    })
  end
  local eventAtPosition = nil
  if tonumber(x) and tonumber(y) then
    eventAtPosition = getSiteZoneEventAtPosition(vec3(tonumber(x), tonumber(y), tonumber(z) or 0))
  end
  return {
    level = data.level,
    sitesFile = data.sitesFile,
    configuredEvents = configuredEvents,
    zoneIdAtPosition = eventAtPosition and eventAtPosition.zoneId or nil,
    occupancy = {
      vehId = siteZoneOccupancy.vehId,
      zoneId = siteZoneOccupancy.zoneId,
      exitElapsed = siteZoneOccupancy.exitElapsed,
    },
  }
end

-- Public API --------------------------------------------------------------------------------------

M.startBurnoutZoneForVehicle = startBurnoutZoneForVehicle
M.stopBurnoutZoneForVehicle = stopBurnoutZoneForVehicle
M.onBurnoutTireWearUpdate = onBurnoutTireWearUpdate
M.onBeamNGTrigger = onBeamNGTrigger
M.onUpdate = onUpdate
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleDestroyed = onVehicleDestroyed
M.onExtensionUnloaded = function()
  for vehId, zoneId in pairs(activeVehicles) do
    local vehicle = getVehicleObject(vehId)
    if vehicle then vehicle:queueLuaCommand("if overhaulBurnoutScorer then overhaulBurnoutScorer.stopSession() end") end
    pcall(hideBurnoutFreHud, vehId, zoneId, true)
    local inventoryId = getInventoryIdForVehicle(vehId)
    if inventoryId and overhaul_career_maintenance_tireSystem then
      overhaul_career_maintenance_tireSystem.setBurnoutOverride(inventoryId, false)
    end
  end
  for vehId in pairs(pendingStopSummaries) do
    if not activeVehicles[vehId] then pcall(hideBurnoutFreHud, vehId, nil, true) end
  end
  activeVehicles = {}
  sessions = {}
  pendingStopSummaries = {}
  pendingStopReasons = {}
  latestSummaries = {}
  burnoutConfig.invalidate()
end
M.onClientEndMission = M.onExtensionUnloaded
M.getLastResult = getLastResult
M.getResultsState = getResultsState
M.getZoneDebugState = getZoneDebugState
M.resolveTriggerZoneId = getZoneIdForTrigger

return M
