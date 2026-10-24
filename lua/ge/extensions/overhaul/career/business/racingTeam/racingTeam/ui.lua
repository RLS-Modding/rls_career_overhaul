-- Racing team UI data: the League 2 invite payload, business computer data with a fallback, goal pushes and the menu.
-- Read map: invite payload, fallback data, fleet rows, pending splashes, UI data build, goal push, menu and liquidation.
local part = {}

-- Invite payload ----------------------------------------------------------------------------------

local function buildRacingTeamLeague2InvitePayload(rtState, parts, businessId, currentLeagueResolved)
  businessId = parts.helpers.normalizeBusinessId(businessId)
  if not businessId then
    return nil
  end
  local lvUiInf = parts.board.getRacingTeamLevelInfo(parts.board.getRacingTeamLevelId())
  local wInv = parts.leagueInvite.getInviteTable(businessId)
  local idPromo = parts.helpers.league2InvitePromoKey(businessId)
  local promoUiState = rtState.league2InvitePromoUiByBusiness[idPromo]
  local leagueForUi = currentLeagueResolved or rtState.rtInternal.getCurrentLeague(businessId)
  local nextLeague = rtState.rtInternal.getNextLeagueForPromotion(leagueForUi)
  local target = wInv.targetLeague or nextLeague or "league2"
  local cfg = rtState.rtInternal.getLeagueInviteConfigForTarget(lvUiInf, target)
  local inviteEligible = nextLeague ~= nil
    and wInv.declined ~= true
    and wInv.offeredAt ~= nil
    and (wInv.targetLeague == nil or wInv.targetLeague == nextLeague)
    and rtState.rtInternal.allGoalsCompleteForLeague(businessId, leagueForUi)
  local league2InviteComputerPopup = inviteEligible and promoUiState == "splash"
  local league2InviteVisible = inviteEligible and promoUiState == "jobs"
  local nowSim = parts.board.getCareerSimTime()
  local league2InviteFeeMinutesUntilEscalate = nil
  local escMinUi = cfg.feeEscalateMinutes
  if wInv.offeredAt then
    local deadline = wInv.offeredAt + escMinUi
    if nowSim < deadline then
      league2InviteFeeMinutesUntilEscalate = math.max(0, math.ceil(deadline - nowSim))
    end
  end
  return {
    visible = league2InviteVisible,
    computerPopup = league2InviteComputerPopup,
    targetLeague = cfg.targetLeague,
    popupTitle = cfg.splashTitle,
    popupBody = cfg.splashBody,
    popupImageUrl = cfg.splashImageUrl,
    acceptLabel = cfg.splashAcceptLabel,
    laterLabel = cfg.splashLaterLabel,
    acronym = cfg.acronym,
    orgName = cfg.orgName,
    fee = parts.leagueInvite.feeAmount(businessId),
    feeEarly = cfg.feeEarly,
    feeLate = cfg.feeLate,
    offeredAtSimTime = wInv.offeredAt,
    escalateAtSimTime = (wInv.offeredAt and (wInv.offeredAt + escMinUi)) or nil,
    minutesUntilEscalate = league2InviteFeeMinutesUntilEscalate,
  }
end

-- Fallback data -----------------------------------------------------------------------------------


-- The fallback shows the team's league when it can still be read, else league 1.
local function fallbackLeague(rtState, businessId)
  local okLeague, v = pcall(rtState.rtInternal.getCurrentLeague, businessId)
  if okLeague and type(v) == "string" and v ~= "" then
    return v
  end
  return "league1"
end

local function fallbackInviteSafe(fbCfg)
  return {
    visible = false,
    computerPopup = false,
    targetLeague = fbCfg.targetLeague,
    popupTitle = fbCfg.splashTitle,
    popupBody = fbCfg.splashBody,
    acceptLabel = fbCfg.splashAcceptLabel,
    laterLabel = fbCfg.splashLaterLabel,
    acronym = fbCfg.acronym,
    orgName = fbCfg.orgName,
    fee = fbCfg.feeEarly,
    feeEarly = fbCfg.feeEarly,
    feeLate = fbCfg.feeLate,
  }
end

-- Rebuilds the invite payload when the league data reads cleanly; otherwise the safe default stays.
local function fallbackLeague2Invite(rtState, parts, businessId, fallbackCfg, safeInvite)
  local okL2, l2Payload = pcall(function()
    local bid = parts.helpers.normalizeBusinessId(businessId)
    if not bid then
      return nil
    end
    rtState.rtInternal.refreshLeague2InviteOffer(bid)
    local _, _, clr = parts.goals.buildDisplays(bid)
    return buildRacingTeamLeague2InvitePayload(rtState, parts, bid, clr)
  end)
  if okL2 and type(l2Payload) == "table" then
    return l2Payload
  end
  return safeInvite
end

local function buildRacingTeamUIDataFallback(rtState, parts, businessId, errMsg)
  parts.board.ensureTabsRegistered()
  local tabs = overhaul_career_business_tabRegistry.getTabs(rtState.businessType) or {}
  local league = fallbackLeague(rtState, businessId)
  log('E', 'racingTeam', 'getUIData failed; using fallback. ' .. tostring(errMsg))
  local fbLev = parts.board.getRacingTeamLevelInfo(parts.board.getRacingTeamLevelId())
  local fbTarget = rtState.rtInternal.getNextLeagueForPromotion(league) or "league2"
  local fbCfg = rtState.rtInternal.getLeagueInviteConfigForTarget(fbLev, fbTarget)
  local league2Invite = fallbackLeague2Invite(rtState, parts, businessId, fbCfg, fallbackInviteSafe(fbCfg))
  return {
    businessDataLoadFailed = true,
    businessId = businessId,
    businessType = rtState.businessType,
    businessName = "Racing Team",
    currentGoal = nil,
    currentLeague = league,
    activeGoals = {},
    completedGoals = {},
    activeJobs = {},
    newJobs = {},
    vehicles = {},
    parts = {},
    pulledOutVehicle = nil,
    pulledOutVehicles = {},
    activeVehicleId = nil,
    maxPulledOutVehicles = 1,
    tabs = tabs,
    techs = {},
    vehicleDamage = 0,
    vehicleDamageLocked = false,
    vehicleDamageThreshold = 1000,
    maxActiveJobs = 3,
    playerInZone = false,
    raceOffers = {},
    raceOffersLevelId = "",
    raceOffersNextRefreshAt = 0,
    raceOffersMessage = "Some racing team data could not be loaded. Check beamng.log for details.",
    racingTeamProxyArmed = false,
    racingTeamManagerSkillLevel = 0,
    racingTeamManagerAutoAssign = false,
    league2Invite = league2Invite,
    racingTeamLeagueDisplayNames = parts.board.shallowCopyTable(fbLev.leagueDisplayNames),
    racingTeamLevelExtra = parts.board.shallowCopyTable(fbLev.extra),
    racingTeamSponsors = {
      available = {},
      active = {},
      sponsorSlots = rtState.K.RACING_TEAM_SPONSOR_MAX_ACTIVE,
      sponsorSlotsUsed = 0,
      bonusMoneyTotal = 0,
      bonusXpTotal = 0,
    },
  }
end

-- Fleet rows --------------------------------------------------------------------------------------


-- Team vehicles still being delivered show as rows with a countdown instead of a vehicle id.
local function appendPendingDeliveries(parts, vehicleList, businessId)
  local shopping = overhaul_career_market_vehicleShopping
  local pending = {}
  if shopping and shopping.getPendingRacingTeamFleetPurchases then
    pending = shopping.getPendingRacingTeamFleetPurchases(businessId) or {}
  end
  local nowEpoch = os.time()
  for _, p in ipairs(pending) do
    local modelKey = p.model_key
    local configKey = p.key
    local name, vehicleYear, vehicleType, vehicleImage =
      require('overhaul/lib/business/helpers').extractDisplayInfo(parts.fleet.getCatalogVehicleInfo(modelKey, configKey))
    local vehicleName = name or modelKey or "Vehicle Delivery"
    table.insert(vehicleList, {
      id = "pending_" .. tostring(p.pendingId or #vehicleList + 1),
      vehicleId = nil,
      vehicleName = vehicleName,
      vehicleYear = vehicleYear,
      vehicleType = vehicleType,
      vehicleImage = vehicleImage,
      storedTime = tonumber(p.purchasedEpoch) or nowEpoch,
      model_key = modelKey,
      config_key = configKey,
      vehicleValue = math.max(0, math.floor(tonumber(p.purchasePrice) or 0)),
      sellValue = 0,
      fleetRepairNeeded = false,
      fleetRepairDeductible = 0,
      deliveryPending = true,
      deliveryMode = tostring(p.kind or "timer"),
      deliveryDueEpoch = tonumber(p.dueEpoch) or 0,
      deliverySecondsRemaining = math.max(0, math.floor(tonumber(p.secondsRemaining) or ((tonumber(p.dueEpoch) or nowEpoch) - nowEpoch))),
    })
  end
end

-- The first pulled-out vehicle is the active one; its damage drives the vehicle gauge.
local function formatPulledOutVehicles(rtState, parts, businessId, pulledOutVehiclesRaw)
  local formattedPulledOutVehicles = {}
  local pulledOutVehicleData = nil
  local activeVehicleId = nil
  local topVehicleDamage = 0
  local topVehicleDamageLocked = false
  for i, vehicle in ipairs(pulledOutVehiclesRaw) do
    local formatted = rtState.formatVehicleForUI(vehicle, businessId)
    if formatted then
      formatted.inGarageZone = true
      formatted.isActive = (i == 1)
      local dmgInfo = parts.fleet.getSpawnedBusinessVehicleDamageInfo(businessId, vehicle.vehicleId)
      formatted.damage = dmgInfo.damage
      formatted.damageLocked = false
      formatted.damageThreshold = dmgInfo.threshold
      table.insert(formattedPulledOutVehicles, formatted)
      if i == 1 then
        pulledOutVehicleData = formatted
        activeVehicleId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
        topVehicleDamage = dmgInfo.damage
        topVehicleDamageLocked = false
      end
    end
  end
  return {formattedPulledOutVehicles = formattedPulledOutVehicles, pulledOutVehicleData = pulledOutVehicleData,
    activeVehicleId = activeVehicleId, topVehicleDamage = topVehicleDamage, topVehicleDamageLocked = topVehicleDamageLocked}
end

local function buildRacingTeamFleetUi(rtState, parts, businessId)
  local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}
  local pulledOutVehiclesRaw = overhaul_career_business_fleet.getPulledOutVehicles(businessId) or {}
  local vehicleList = {}
  for _, vehicle in ipairs(vehicles) do
    local formatted = rtState.formatVehicleForUI(vehicle, businessId)
    if formatted then
      table.insert(vehicleList, formatted)
    end
  end
  appendPendingDeliveries(parts, vehicleList, businessId)
  local pulled = formatPulledOutVehicles(rtState, parts, businessId, pulledOutVehiclesRaw)
  pulled.vehicleList = vehicleList
  return pulled
end

-- Pending splashes --------------------------------------------------------------------------------


-- A splash is shown once: the pending flag is cleared and the shown flag is set before the save.
local function presentPendingRacingTeamSplashes(rtState, parts, businessId, id)
  if rtState.raceUnlockSplashPendingByBusiness[id] then
    rtState.raceUnlockSplashPendingByBusiness[id] = false
    local shouldShowRaceUnlockSplash = rtState.raceUnlockSplashShownByBusiness[id] ~= true
    if shouldShowRaceUnlockSplash then
      rtState.raceUnlockSplashShownByBusiness[id] = true
    end
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if savePath then
      parts.persist.saveRacingTeamPersistedState(businessId, savePath)
    end
    if shouldShowRaceUnlockSplash then
      core_jobsystem.create(function(job)
        job.sleep(0.35)
        rtState.rtInternal.triggerRacingTeamMilestoneSplashShow(businessId, "race_unlock")
      end)
    end
  end
  if rtState.careerFinaleSplashPendingByBusiness[id] then
    rtState.careerFinaleSplashPendingByBusiness[id] = false
    if rtState.careerFinaleSplashShownByBusiness[id] ~= true then
      local _, savePathFinale = overhaul_career_saveSystem.getCurrentProfile()
      if savePathFinale then
        parts.persist.saveRacingTeamPersistedState(businessId, savePathFinale)
      end
      rtState.rtInternal.scheduleCareerFinaleSplash(businessId)
    end
  end
end

-- UI data build -----------------------------------------------------------------------------------

local function resolveSavedBusinessName(rtState, businessId, businessName)
  local savedInfo = overhaul_career_business_manager.getBusinessInfo(rtState.businessType, businessId)
  if savedInfo and savedInfo.name then
    return savedInfo.name
  end
  return businessName
end

-- Goals are reconciled before the view reads them, so the computer never shows a goal that is already done.
local function buildGoalsView(rtState, parts, businessId)
  rtState.rtInternal.advanceRacingTeamGoalsIfReady(businessId)
  local currentGoal, activeGoals, currentLeagueResolved = parts.goals.buildDisplays(businessId)
  rtState.rtInternal.refreshLeague2InviteOffer(businessId)
  return {
    currentGoal = currentGoal,
    activeGoals = activeGoals,
    currentLeagueResolved = currentLeagueResolved,
    completedGoals = parts.goals.getCompletedList(businessId),
  }
end

local function buildTechEntries(rtState, parts, businessId)
  rtState.loadRacingTeamDrivers(businessId)
  local techEntries = {}
  for _, tech in ipairs(parts.board.getRacingTeamDriversRawForUI(businessId)) do
    local formattedTech = parts.results.formatRacingTeamDriverForUI(businessId, tech)
    if formattedTech then
      table.insert(techEntries, formattedTech)
    end
  end
  return techEntries
end

-- Sanctioned offers are copied in order; each one gets its display horsepower when the display module is loaded.
local function buildRaceOffersView(rtState, parts, businessId)
  local raceBoard = parts.raceOffers.ensureBoard(businessId)
  local raceOffersRaw = raceBoard.offers or {}
  local raceOffers = {}
  if type(raceOffersRaw) == "table" then
    local srDisp = overhaul_events_fre_sanctionedRacing
    for _, o in ipairs(raceOffersRaw) do
      if srDisp and type(srDisp.attachSanctionedOfferDisplayHp) == "function" then
        srDisp.attachSanctionedOfferDisplayHp(o)
      end
      table.insert(raceOffers, o)
    end
  end
  local lvUiInf = parts.board.getRacingTeamLevelInfo(parts.board.getRacingTeamLevelId())
  local raceOffersMessage = nil
  if raceBoard.levelId == "" then
    raceOffersMessage = "Open the business computer while on a career map to load sanctioned race offers."
  elseif #raceOffers == 0 then
    raceOffersMessage = lvUiInf.msgNoSanctionedRaces
  end
  return {raceBoard = raceBoard, raceOffers = raceOffers, raceOffersMessage = raceOffersMessage, lvUiInf = lvUiInf}
end

local function readManagerSkillLevel(businessId)
  return math.max(0, math.floor(tonumber(overhaul_career_business_skillTree.getNodeProgress(businessId, "team-operations", "manager")) or 0))
end

-- The manager's timing fields only exist once the manager skill is trained; the due assignment runs first.
local function buildManagerView(racingTeamManager, businessId)
  local view = { skillLevel = readManagerSkillLevel(businessId), autoAssign = false }
  if racingTeamManager() then
    view.autoAssign = racingTeamManager().getManagerAutoAssignEnabled(businessId)
  end
  if racingTeamManager() and view.skillLevel > 0 then
    pcall(racingTeamManager().processAssignDueNow, businessId)
    view.assignIntervalSec = racingTeamManager().getManagerAssignIntervalSec(businessId)
    view.assignIntervalRemainingSec = racingTeamManager().getManagerAssignIntervalRemainingSec(businessId)
    view.nextAssignWallEpoch = racingTeamManager().getManagerNextAssignWallEpoch(businessId)
    view.assignIntervalOptions = racingTeamManager().getAssignIntervalOptionsForUI()
  end
  return view
end

local function buildFleetCooldowns(parts, businessId)
  local out = {}
  local inv = overhaul_career_business_fleet
  do
    local vehs = inv.getBusinessVehicles(businessId) or {}
    for _, v in ipairs(vehs) do
      local vid = v and (tonumber(v.vehicleId) or v.vehicleId)
      if vid ~= nil then
        local sec = parts.fleet.getFleetVehiclePostRaceCooldownRemainingSec(businessId, vid) or 0
        if sec > 0 then
          out[tostring(vid)] = sec
        end
      end
    end
  end
  return out
end

-- League and goal fields of the UI data, with the invite payload built from the goals just reconciled.
local function buildUiLeagueFields(rtState, parts, businessId, goals, lvUiInf)
  return {
    currentLeague = goals.currentLeagueResolved or rtState.rtInternal.getCurrentLeague(businessId),
    league2Invite = buildRacingTeamLeague2InvitePayload(rtState, parts, businessId, goals.currentLeagueResolved),
    racingTeamLeagueDisplayNames = parts.board.shallowCopyTable(lvUiInf.leagueDisplayNames),
    racingTeamLevelExtra = parts.board.shallowCopyTable(lvUiInf.extra),
    currentGoal = goals.currentGoal,
    activeGoals = goals.activeGoals,
    completedGoals = goals.completedGoals,
  }
end

-- The sponsor state is read before the manager block runs, as the sponsor totals always were.
local function buildUiSponsorFields(rtState, sponsorState, spMoney, spXp)
  return {
    racingTeamSponsors = {
      available = sponsorState.available or {},
      active = sponsorState.active or {},
      sponsorSlots = rtState.K.RACING_TEAM_SPONSOR_MAX_ACTIVE,
      sponsorSlotsUsed = #(sponsorState.active or {}),
      bonusMoneyTotal = spMoney,
      bonusXpTotal = spXp,
    },
  }
end

local function buildUiVehicleFields(parts, businessId, fleet, offerState, techEntries)
  return {
    activeJobs = offerState.active or {},
    newJobs = offerState.new or {},
    vehicles = fleet.vehicleList,
    parts = {},
    pulledOutVehicle = fleet.pulledOutVehicleData,
    pulledOutVehicles = fleet.formattedPulledOutVehicles,
    activeVehicleId = fleet.activeVehicleId,
    techs = techEntries,
    vehicleDamage = fleet.topVehicleDamage,
    vehicleDamageLocked = fleet.topVehicleDamageLocked,
    vehicleDamageThreshold = parts.fleet.getDamageThreshold(businessId),
    maxActiveJobs = parts.board.getMaxActiveJobs(businessId),
  }
end

local function buildUiRaceFields(parts, businessId, offers)
  local raceBoard = offers.raceBoard
  return {
    playerInZone = false,
    raceOffers = offers.raceOffers,
    raceOffersLevelId = raceBoard.levelId or "",
    raceOffersNextRefreshAt = tonumber(raceBoard.nextRefreshAt) or 0,
    raceOffersMessage = offers.raceOffersMessage,
    racingTeamProxyArmed = (function()
      local pr = parts.dispatch.getProxyDriverRaceRequest(businessId)
      return pr ~= nil and pr.racingTeamProxyRace == true
    end)(),
  }
end

local function buildUiManagerFields(manager)
  return {
    racingTeamManagerSkillLevel = manager.skillLevel,
    racingTeamManagerAutoAssign = manager.autoAssign,
    racingTeamManagerAssignIntervalSec = manager.assignIntervalSec,
    racingTeamManagerAssignIntervalRemainingSec = manager.assignIntervalRemainingSec,
    racingTeamManagerNextAssignWallEpoch = manager.nextAssignWallEpoch,
    racingTeamManagerAssignIntervalOptions = manager.assignIntervalOptions,
  }
end

-- The tabs are registered before they are read, so the computer always has the team's full tab list.
local function readTabs(rtState, parts)
  parts.board.ensureTabsRegistered()
  pcall(overhaul_career_business_skillTree.ensureTabsRegistered, rtState.businessType)
  return overhaul_career_business_tabRegistry.getTabs(rtState.businessType) or {}
end

local function mergeFields(target, fields)
  for key, value in pairs(fields) do
    target[key] = value
  end
  return target
end

local function buildRacingTeamUIDataCore(rtState, parts, racingTeamBuildClass, racingTeamManager, businessId)
  racingTeamBuildClass.warmupCatalogBaselines()
  local business = overhaul_world_facilities.getFacility(rtState.businessType, businessId)
  local businessName = (business and business.name) or "Racing Team"
  local offerState = parts.helpers.getOfferState(businessId)
  local id = tostring(parts.helpers.normalizeBusinessId(businessId))
  parts.sponsors.tickOffers(businessId)
  if not business then
    businessName = resolveSavedBusinessName(rtState, businessId, businessName)
  end

  local fleet = buildRacingTeamFleetUi(rtState, parts, businessId)
  local goals = buildGoalsView(rtState, parts, businessId)
  presentPendingRacingTeamSplashes(rtState, parts, businessId, id)
  local techEntries = buildTechEntries(rtState, parts, businessId)
  local offers = buildRaceOffersView(rtState, parts, businessId)
  local sponsorState = parts.sponsors.getState(businessId)
  local spMoney, spXp = parts.sponsors.bonusTotals(businessId)
  local manager = buildManagerView(racingTeamManager, businessId)

  local data = {
    businessId = businessId,
    businessType = rtState.businessType,
    businessName = businessName,
  }
  -- Field order below is the order the sibling calls always ran in; the business computer tests pin it.
  mergeFields(data, buildUiLeagueFields(rtState, parts, businessId, goals, offers.lvUiInf))
  mergeFields(data, buildUiSponsorFields(rtState, sponsorState, spMoney, spXp))
  data.maxPulledOutVehicles = parts.board.getMaxPulledOutVehicles(businessId)
  data.tabs = readTabs(rtState, parts)
  mergeFields(data, buildUiVehicleFields(parts, businessId, fleet, offerState, techEntries))
  mergeFields(data, buildUiRaceFields(parts, businessId, offers))
  mergeFields(data, buildUiManagerFields(manager))
  data.racingTeamFleetCooldowns = buildFleetCooldowns(parts, businessId)
  return data
end

local function getUIData(rtState, parts, racingTeamBuildClass, racingTeamManager, businessId)
  if not businessId then
    return nil
  end
  local ok, result = pcall(buildRacingTeamUIDataCore, rtState, parts, racingTeamBuildClass, racingTeamManager, businessId)
  if ok then
    return result
  end
  return buildRacingTeamUIDataFallback(rtState, parts, businessId, result)
end

-- Goal pushes -------------------------------------------------------------------------------------

local function pushGoalsToBusinessComputer(rtState, parts, businessId)
  businessId = parts.helpers.normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local uid = rtState.rtInternal.getUIData(businessId)
  if not uid then
    return
  end
  local inv = uid.league2Invite
  local cp = inv and inv.computerPopup
  local vis = inv and inv.visible
  local msg = string.format(
    "[racingTeam] pushRacingTeamGoalsToBusinessComputer: bid=%s computerPopup=%s visible=%s -> onRacingTeamGoals",
    tostring(businessId),
    tostring(cp),
    tostring(vis)
  )
  log("I", "racingTeam", msg)
  guihooks.trigger("businessComputer:onRacingTeamGoals", {
    businessId = businessId,
    currentGoal = uid.currentGoal,
    currentLeague = uid.currentLeague,
    completedGoals = uid.completedGoals,
    league2Invite = uid.league2Invite,
    vehicles = uid.vehicles,
  })
end

-- The computer push runs twice, so a newer goal completion cancels the older queued push.
local function scheduleDeferredGoalsPush(rtState, parts, businessId)
  businessId = parts.helpers.normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local id = tostring(businessId)
  rtState.rtInternal.goalsPushToken[id] = (rtState.rtInternal.goalsPushToken[id] or 0) + 1
  local token = rtState.rtInternal.goalsPushToken[id]
  local initialDelay = 2.5
  local retryGap = 2.0
  local function doPushIfCurrent()
    if rtState.rtInternal.goalsPushToken[id] ~= token then
      return
    end
    rtState.rtInternal.pushRacingTeamGoalsToBusinessComputer(businessId)
  end
  core_jobsystem.create(function(job)
    job.sleep(initialDelay)
    doPushIfCurrent()
    job.sleep(retryGap)
    doPushIfCurrent()
  end)
end

-- Menu and liquidation ----------------------------------------------------------------------------

local function openMenu(rtState, businessId)
  extensions.ui_router.navigate('business-computer', {
    businessType = rtState.businessType,
    businessId = businessId
  })
end

local function getLiquidationValue(parts, businessId)
  local total = 0
  for _, vehicle in ipairs(overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}) do
    total = total + (parts.fleet.getTeamVehicleSellValue(vehicle, 0) or 0)
  end
  total = total + (overhaul_career_business_partInventory.getLiquidationValue(businessId) or 0)
  return math.floor(total + 0.5)
end

-- Public API: instance construction ---------------------------------------------------------------

function part.new(inputs)
  local parts = inputs.parts
  local racingTeamManager = inputs.racingTeamManager
  local racingTeamBuildClass = inputs.racingTeamBuildClass
  local rtState = inputs.rtState
  rtState.rtInternal.getUIData = function(businessId)
    return getUIData(rtState, parts, racingTeamBuildClass, racingTeamManager, businessId)
  end
  rtState.rtInternal.pushRacingTeamGoalsToBusinessComputer = function(businessId)
    return pushGoalsToBusinessComputer(rtState, parts, businessId)
  end
  rtState.rtInternal.notifyBusinessComputerRacingTeamGoalProgress = function(businessId, goalId)
    if goalId ~= rtState.K.GOAL_TIER1_LAST then
      return
    end
    scheduleDeferredGoalsPush(rtState, parts, businessId)
  end
  return {
    getLiquidationValue = function(businessId)
      return getLiquidationValue(parts, businessId)
    end,
    openMenu = function(businessId)
      return openMenu(rtState, businessId)
    end,
  }
end

return part
