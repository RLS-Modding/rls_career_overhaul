-- Derby staging, introduction, countdown warnings and elimination displays.
-- Read UI state, presentation helpers, user actions, lifecycle and public services.
local eventConfig = require("overhaul/events/derby/config")
local hudSnapshot = require("overhaul/lib/ui/hudSnapshot")
local M = {}

local MAX_SELECTABLE_AI_OPPONENTS = 9

local deps = {}

local introDismissedForVisit = {}

local stagingShown = false
local congratsShown = false
local activeStagingEventKey = nil
local activeStagingStartEnabled = nil
local dismissedStagingEventKey = nil
local activeStagingPhase = nil

local noContactWarningActive = false
local stationaryWarningActive = false

function M.setDeps(newDeps)
  if type(newDeps) ~= "table" then return end
  deps = newDeps
end

-- Intro persistence -------------------------------------------------------------------------------

local function getGuideExtension()
  return rawget(_G, "overhaul_career_guide_guide")
end

local function shouldSkipDemoIntro(eventKey)
  local guide = getGuideExtension()
  if guide and guide.shouldSkipDemoIntro then return guide.shouldSkipDemoIntro(eventKey) == true end
  return false
end

local function shouldShowIntroForEvent(eventKey)
  if not (overhaul_career_career and overhaul_career_career.isActive()) then
    return false
  end
  local cfg = deps.derbyArena.getEventConfig(eventKey)
  if type(cfg) == "table" and cfg.introSplash == false then return false end
  return not shouldSkipDemoIntro(eventKey)
end

local function appendIntroFieldsToPayload(payload, eventKey)
  if type(payload) ~= "table" then return end
  local cfg = deps.derbyArena.getEventConfig(eventKey)
  local splash = type(cfg) == "table" and cfg.introSplash or nil
  if type(splash) ~= "table" then splash = {} end
  local features = splash.features
  if type(features) ~= "table" then features = {} end
  payload.introTitle = splash.title or (cfg and cfg.label) or "Demolition Derby"
  payload.introSubtitle = splash.subtitle or ""
  payload.introBody = splash.body or ""
  payload.introFeatures = features
  payload.introContinueLabel = splash.continueLabel or "Continue"
end

function M.persistIntroSkip(eventKey)
  eventKey = eventKey or activeStagingEventKey
  if not eventKey or eventKey == "" then
    log("E", "demolitionDerbyUi", "persistIntroSkip: missing eventKey")
    return
  end
  local guide = getGuideExtension()
  if not guide or not guide.markDemoIntroSkipped then
    log("E", "demolitionDerbyUi", "overhaul_career_guide_guide unavailable; cannot persist demo intro skip")
    return
  end
  if not guide.markDemoIntroSkipped(eventKey) then
    log("E", "demolitionDerbyUi", "markDemoIntroSkipped failed for " .. tostring(eventKey))
  end
end

function M.dismissIntroVisit(dontShowAgain, eventKey)
  eventKey = eventKey or activeStagingEventKey
  if not eventKey or eventKey == "" then return end
  if dontShowAgain == true or dontShowAgain == 1 or tostring(dontShowAgain) == "true" then
    M.persistIntroSkip(eventKey)
  end
  introDismissedForVisit[eventKey] = true
end

function M.clearVisitDismissal(eventKey)
  introDismissedForVisit[eventKey] = nil
end

function M.resetCareerState()
  introDismissedForVisit = {}
end

function M.onOverhaulModulesActivated()
  introDismissedForVisit = {}
end

function M.wasDismissedThisVisit(eventKey)
  return introDismissedForVisit[eventKey] == true
end

-- Scenario flash and in-event warnings ------------------------------------------------------------

function M.clearNoContactWarning()
  if noContactWarningActive then guihooks.trigger("ScenarioFlashMessage", { msg = "", ttl = 0, clearQueue = true }) end
  noContactWarningActive = false
end

function M.clearStationaryWarning()
  if stationaryWarningActive then guihooks.trigger("ScenarioFlashMessage", { msg = "", ttl = 0, clearQueue = true }) end
  stationaryWarningActive = false
end

function M.clearDerbyCountdownWarnings()
  local hadWarning = noContactWarningActive or stationaryWarningActive
  noContactWarningActive = false
  stationaryWarningActive = false
  if hadWarning then guihooks.trigger("ScenarioFlashMessage", { msg = "", ttl = 0, clearQueue = true }) end
end

function M.resetScenarioFlash()
  guihooks.trigger("ScenarioFlashMessage", { msg = "", ttl = 0, clearQueue = true })
end

function M.triggerScenarioFlash(messages)
  guihooks.trigger("ScenarioFlashMessage", messages)
end

local function showDerbyCountdownWarning(timeLeft, messagePrefix)
  local seconds = math.max(1, math.ceil(timeLeft))
  local messages = {}
  for i = seconds, 1, -1 do
    table.insert(messages, {
      tostring(messagePrefix) .. ": " .. tostring(i),
      1,
      "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown" .. tostring(((i - 1) % 3) + 1) .. "')",
      false,
    })
  end
  guihooks.trigger("ScenarioFlashMessage", { msg = "", ttl = 0, clearQueue = true })
  guihooks.trigger("ScenarioFlashMessage", messages)
end

function M.showNoContactWarning(timeLeft)
  if noContactWarningActive then return end
  showDerbyCountdownWarning(timeLeft, "Make contact")
  noContactWarningActive = true
end

function M.showStationaryWarning(timeLeft)
  if stationaryWarningActive then return end
  showDerbyCountdownWarning(timeLeft, "Keep moving")
  stationaryWarningActive = true
end

function M.showEliminationToast(data)
  guihooks.trigger("DemoEliminationToast", data)
end

-- Staging UI --------------------------------------------------------------------------------------

function M.isStagingShown()
  return stagingShown
end

function M.getActiveStagingEventKey()
  return activeStagingEventKey
end

function M.getActiveStagingPhase()
  return activeStagingPhase
end

function M.markStagingDismissed(eventKey)
  dismissedStagingEventKey = eventKey
end

function M.emitDemoStagingUi(payload)
  guihooks.trigger("DemoStagingUi", payload)
end

function M.showStagingPopup(eventKey, phase)
  local cfg = deps.derbyArena.getEventConfig(eventKey)
  if not cfg then return end

  phase = phase or "configure"
  if phase ~= "intro" then deps.derbyArena.resolveAllSpatialData(cfg) end

  local resolvedSpots = deps.getResolvedSpots()
  local availableAiSpots = resolvedSpots and math.max(#resolvedSpots - 1, 0) or 0
  local maxAi = math.min(tonumber(cfg.maxOpponents) or 10, MAX_SELECTABLE_AI_OPPONENTS, availableAiSpots)
  maxAi = math.max(0, maxAi)
  activeStagingEventKey = eventKey
  activeStagingPhase = phase
  deps.setActiveEntryModeKey("loaner")
  local canStart, startDisabledReason = deps.derbyParticipants.getStagingStartAvailability(maxAi, "loaner")

  local payload = {
    visible = true,
    phase = phase,
    maxAi = maxAi,
    eventKey = eventKey,
    label = cfg.label or "Demolition Derby",
    selectedMode = "loaner",
    modeOptions = deps.derbyRewards.buildModeOptions(cfg, math.max(1, math.min(3, maxAi))),
    startEnabled = canStart,
    startDisabledReason = startDisabledReason,
  }
  if phase == "intro" then
    appendIntroFieldsToPayload(payload, eventKey)
  elseif phase ~= "ready" then
    local insuranceFields = deps.derbyRewards.buildWinnerRepairInsurancePayload(cfg, "loaner", nil)
    for fieldKey, fieldValue in pairs(insuranceFields) do
      payload[fieldKey] = fieldValue
    end
  end
  M.emitDemoStagingUi(payload)
  stagingShown = true
  activeStagingStartEnabled = canStart
end

function M.hideStagingPopup()
  M.emitDemoStagingUi({ visible = false })
  stagingShown = false
  activeStagingEventKey = nil
  activeStagingPhase = nil
  activeStagingStartEnabled = nil
end

function M.refreshStagingAvailability(modeKey, aiCount, winnerRepairInsurance)
  if not stagingShown or not activeStagingEventKey or activeStagingPhase == "intro" then return end
  local cfg = deps.derbyArena.getEventConfig(activeStagingEventKey)
  if not cfg then return end

  local resolvedSpots = deps.getResolvedSpots()
  local availableAiSpots = resolvedSpots and math.max(#resolvedSpots - 1, 0) or 0
  local maxAi = math.min(tonumber(cfg.maxOpponents) or 10, MAX_SELECTABLE_AI_OPPONENTS, availableAiSpots)
  maxAi = math.max(0, maxAi)
  local selectedAiCount = math.max(1, math.min(math.floor(tonumber(aiCount) or 1), math.max(1, maxAi)))
  local selectedModeKey = tostring(modeKey or "loaner")
  deps.setActiveEntryModeKey(selectedModeKey)
  local canStart, startDisabledReason = deps.derbyParticipants.getStagingStartAvailability(maxAi, selectedModeKey)

  activeStagingStartEnabled = canStart
  local payload = {
    visible = true,
    phase = "configure",
    maxAi = maxAi,
    aiCount = selectedAiCount,
    eventKey = activeStagingEventKey,
    label = cfg.label or "Demolition Derby",
    selectedMode = selectedModeKey,
    modeOptions = deps.derbyRewards.buildModeOptions(cfg, selectedAiCount),
    startEnabled = canStart,
    startDisabledReason = startDisabledReason,
  }
  local insuranceSelected = nil
  if type(winnerRepairInsurance) == "boolean" then insuranceSelected = winnerRepairInsurance end
  local insuranceFields = deps.derbyRewards.buildWinnerRepairInsurancePayload(cfg, selectedModeKey, insuranceSelected)
  for fieldKey, fieldValue in pairs(insuranceFields) do
    payload[fieldKey] = fieldValue
  end
  M.emitDemoStagingUi(payload)
end

local function resolveStagingStartSpot(eventKey, cfg)
  local spotName = type(cfg and cfg.startSpotName) == "string" and cfg.startSpotName or nil
  if not spotName or spotName == "" then spotName = "start_" .. tostring(eventKey or "") end
  return deps.derbyArena.resolveParkingSpotByName(spotName, eventKey), spotName
end

-- Start-spot boxes only depend on the loaded config and sites tables.
local startBoxes = {}
local startBoxesConfig, startBoxesSites

local function getStartSpotBoxes()
  local configData, sitesData = deps.getLoadedData()
  if configData == startBoxesConfig and sitesData == startBoxesSites then return startBoxes end
  local getAvailableEventKeys = deps.derbyArena.getAvailableEventKeys
  local getEventConfig = deps.derbyArena.getEventConfig
  local boxes = {}
  for _, key in ipairs(getAvailableEventKeys()) do
    local cfg = getEventConfig(key)
    if cfg then
      local startSpot = resolveStagingStartSpot(key, cfg)
      if startSpot and startSpot.pos then
        local rotQ = quat(0, 0, 0, 1)
        if startSpot.rot then rotQ = quat(startSpot.rot[1], startSpot.rot[2], startSpot.rot[3], startSpot.rot[4]) end
        local hw = 1.6
        local hl = 3.0
        if startSpot.scl then
          hw = (startSpot.scl[1] or 3.2) * 0.5
          hl = (startSpot.scl[2] or 6.0) * 0.5
        end
        table.insert(boxes, {
          key = key,
          pos = vec3(startSpot.pos[1], startSpot.pos[2], startSpot.pos[3]),
          xDir = rotQ * vec3(1, 0, 0),
          yDir = rotQ * vec3(0, 1, 0),
          hw = hw,
          hl = hl,
        })
      end
    end
  end
  startBoxes, startBoxesConfig, startBoxesSites = boxes, configData, sitesData
  return boxes
end

local function getEventKeyAtStartSpot()
  if not deps.derbyParticipants.ensureConfigAndSites() then return nil end

  local playerPos = deps.derbyParticipants.getPlayerStagingReferencePos()
  if not playerPos then return nil end

  local boxes = getStartSpotBoxes()
  for i = 1, #boxes do
    local box = boxes[i]
    local startPos, xDir, yDir = box.pos, box.xDir, box.yDir
    local dx, dy, dz = playerPos.x - startPos.x, playerPos.y - startPos.y, playerPos.z - startPos.z
    local lx = math.abs(dx * xDir.x + dy * xDir.y + dz * xDir.z)
    local ly = math.abs(dx * yDir.x + dy * yDir.y + dz * yDir.z)
    local lz = math.abs(dz)
    if lx <= box.hw + 1.0 and ly <= box.hl + 1.0 and lz <= 5.0 then return box.key end
  end

  return nil
end

function M.updateStagingPopupFromStartSpots()
  local eventActive, eventPhase, anotherActivityActive = deps.getFlowState()
  if eventActive or anotherActivityActive then
    if stagingShown then
      M.hideStagingPopup()
      deps.onStagingTeardownSpatial()
    end
    return
  end
  if eventPhase ~= "idle" then return end

  local keyAtSpot = getEventKeyAtStartSpot()
  if keyAtSpot then
    if dismissedStagingEventKey == keyAtSpot then
      if stagingShown then M.hideStagingPopup() end
      return
    end
    if shouldShowIntroForEvent(keyAtSpot) and not introDismissedForVisit[keyAtSpot] then
      if not stagingShown or activeStagingEventKey ~= keyAtSpot or activeStagingPhase ~= "intro" then
        M.showStagingPopup(keyAtSpot, "intro")
      end
      return
    end

    local entryModeKey = deps.getActiveEntryModeKey() or "loaner"
    if not stagingShown then
      M.showStagingPopup(keyAtSpot)
    elseif activeStagingEventKey ~= keyAtSpot then
      M.hideStagingPopup()
      M.showStagingPopup(keyAtSpot)
    else
      local canStartNow = select(1, deps.derbyParticipants.getStagingStartAvailability(nil, entryModeKey))
      if activeStagingStartEnabled ~= canStartNow then M.showStagingPopup(keyAtSpot) end
    end
  elseif stagingShown then
    M.hideStagingPopup()
    deps.onStagingTeardownSpatial()
    dismissedStagingEventKey = nil
  else
    dismissedStagingEventKey = nil
  end
end

function M.handleMarkerStagingEnter(eventKey, host)
  if not eventKey or eventKey == "" or type(host) ~= "table" then return end
  if host.eventActive or host.isAnotherActivityActive then return end
  if host.ensureConfigLoaded and not host.ensureConfigLoaded() then return end
  if dismissedStagingEventKey == eventKey then return end
  local phase = "configure"
  if shouldShowIntroForEvent(eventKey) and not introDismissedForVisit[eventKey] then phase = "intro" end
  M.showStagingPopup(eventKey, phase)
end

function M.onMarkerStagingExit(eventKey)
  M.clearVisitDismissal(eventKey)
  if stagingShown and activeStagingEventKey == eventKey and getEventKeyAtStartSpot() ~= eventKey then
    M.hideStagingPopup()
    deps.onStagingTeardownSpatial()
  end
end

function M.dismissIntroAndShowConfigure(dontShowAgain, eventKey)
  eventKey = eventKey or activeStagingEventKey
  if not eventKey then return end
  M.dismissIntroVisit(dontShowAgain, eventKey)
  M.showStagingPopup(eventKey, "configure")
end

-- Results and in-race HUD -------------------------------------------------------------------------

local function buildParticipants()
  local ordinal = deps.ordinal
  local getVehicleDamageNormalized = deps.derbyParticipants.getVehicleDamageNormalized

  local snap = deps.derbyParticipants.getDerbyEventSnapshot()
  local derbyDamageScoring = deps.getDerbyDamageScoring()
  local participants = {}

  local playerVehId = snap.playerDerbyVehicleId or be:getPlayerVehicleID(0)
  local playerDmg = 0
  if playerVehId then playerDmg = getVehicleDamageNormalized(playerVehId, true) end
  local playerScoring = derbyDamageScoring.getParticipantData(playerVehId, playerDmg)
  table.insert(participants, {
    label = "You",
    isPlayer = true,
    status = snap.playerEliminated and "eliminated"
      or ((snap.eventFinishReason == "time_limit") and "survived" or "alive"),
    damagePct = playerDmg,
    healthScore = playerScoring.healthScore,
    damageDealt = playerScoring.damageDealt,
    damageDealtScore = playerScoring.damageDealtScore,
    derbyScore = playerScoring.derbyScore,
    placement = snap.playerPlacement,
    placementStr = snap.playerPlacement and ordinal(snap.playerPlacement) or nil,
  })

  for _, vehId in ipairs(snap.spawnedAiIds or {}) do
    local info = (snap.spawnedAiInfo or {})[vehId] or {}
    local elimData = (snap.eliminatedIds or {})[vehId]
    local isElim = elimData and true or false
    local dmg = 0
    if elimData and elimData.timedOutSurvivor then
      dmg = tonumber(elimData.damagePct) or getVehicleDamageNormalized(vehId, false)
    elseif not isElim then
      dmg = getVehicleDamageNormalized(vehId, false)
    end
    local aiScoring = derbyDamageScoring.getParticipantData(vehId, dmg)
    local pl = elimData and elimData.placement or nil
    table.insert(participants, {
      label = "AI #" .. tostring(info.index or "?") .. " (" .. tostring(info.model or "?") .. ")",
      isPlayer = false,
      status = (elimData and elimData.timedOutSurvivor) and "survived" or (isElim and "eliminated" or "alive"),
      damagePct = dmg,
      healthScore = aiScoring.healthScore,
      damageDealt = aiScoring.damageDealt,
      damageDealtScore = aiScoring.damageDealtScore,
      derbyScore = aiScoring.derbyScore,
      placement = pl,
      placementStr = pl and ordinal(pl) or nil,
    })
  end

  return participants
end

function M.showCongratulations(isPlayerEliminated, playerPlace, eliminationReason, rewardSummary)
  local snap = deps.derbyParticipants.getDerbyEventSnapshot()
  local placeStr = playerPlace and deps.ordinal(playerPlace) or nil
  local rewards = rewardSummary or snap.lastRewardSummary or {}
  local playerDamage = snap.playerDerbyVehicleId
      and deps.derbyParticipants.getVehicleDamageNormalized(snap.playerDerbyVehicleId, true)
    or 0
  local derbyDamageScoring = deps.getDerbyDamageScoring()
  local playerScore = snap.playerDerbyVehicleId
      and derbyDamageScoring
      and derbyDamageScoring.getParticipantData(snap.playerDerbyVehicleId, playerDamage)
    or nil
  local fee = math.max(
    0,
    math.floor(tonumber(rewards.entryFee or (snap.activeEntryModeCfg and snap.activeEntryModeCfg.entryFee)) or 0)
  )
  local repairCut = math.max(0, math.floor(tonumber(rewards.repairCut) or 0))
  local money = math.floor(tonumber(rewards.money) or 0)
  local grossMoney = math.max(money, math.floor(tonumber(rewards.grossMoney) or (money + repairCut)))

  guihooks.trigger("DemoCongratulationsUi", {
    visible = true,
    playerEliminated = isPlayerEliminated or false,
    playerPlacement = playerPlace,
    playerPlacementStr = placeStr,
    eliminationReason = eliminationReason,
    finishReason = snap.eventFinishReason or eliminationReason or "completed",
    modeKey = rewards.modeKey or snap.activeEntryModeKey,
    modeLabel = rewards.modeLabel
      or (snap.activeEntryModeCfg and snap.activeEntryModeCfg.label)
      or snap.activeEntryModeKey,
    entryFee = fee,
    repairCut = repairCut,
    rewardGrossMoney = grossMoney,
    rewardNetMoney = money - fee,
    rewardMoney = grossMoney,
    rewardXp = math.floor(tonumber(rewards.xp) or 0),
    rewardEligible = rewards.eligible == true,
    rewardNoRewardDetail = rewards.noRewardDetail,
    aiCount = math.max(0, (snap.totalParticipants or 1) - 1),
    durationSeconds = deps.getElapsedEventTime() or 0,
    playerDamagePct = playerDamage,
    playerScore = playerScore,
    participants = buildParticipants(),
  })
  congratsShown = true
end

function M.hideCongratulations()
  guihooks.trigger("DemoCongratulationsUi", { visible = false })
  congratsShown = false
end

function M.isCongratulationsShown()
  return congratsShown
end

local function buildDemoHudState()
  local getSnapshot = deps.derbyParticipants.getDerbyEventSnapshot
  if not getSnapshot then return end
  local snap = getSnapshot()
  if not snap.eventActive then return end

  local total = #(snap.spawnedAiIds or {}) + 1
  local alive = snap.playerEliminated and 0 or 1
  for _, id in ipairs(snap.spawnedAiIds or {}) do
    if not (snap.eliminatedIds or {})[id] then alive = alive + 1 end
  end

  local timeLimit = eventConfig.value(snap.activeEventCfg, "timeLimitSeconds")
  local getElapsedEventTime = deps.getElapsedEventTime
  local elapsed = getElapsedEventTime and getElapsedEventTime() or 0
  local timeRemaining = timeLimit > 0 and math.max(0, timeLimit - elapsed) or nil

  return {
    raceLabel = (snap.activeEventCfg and snap.activeEventCfg.label) or "Demolition Derby",
    phase = "racing",
    routeName = "Demo Arena",
    demoMode = true,
    demoAiAlive = alive,
    demoAiTotal = total,
    demoTimeLimitSeconds = timeLimit,
    demoTimeRemainingSeconds = timeRemaining,
    demoPlayerElim = snap.playerEliminated,
    demoParticipants = buildParticipants(),
  }
end

function M.pushDemoHudState()
  local payload = buildDemoHudState()
  if payload then guihooks.trigger("FreeroamRaceHudState", payload) end
end

function M.showDemoHud()
  local snapshot = hudSnapshot.build(buildDemoHudState(), "freeroamRaceHudLayout")
  if snapshot then guihooks.trigger("FreeroamRaceHudShow", snapshot) end
end

function M.hideDemoHud()
  guihooks.trigger("FreeroamRaceHudHide")
end

function M.shutdownAll()
  M.hideStagingPopup()
  M.clearNoContactWarning()
  M.hideCongratulations()
  M.hideDemoHud()
  dismissedStagingEventKey = nil
end

return M
