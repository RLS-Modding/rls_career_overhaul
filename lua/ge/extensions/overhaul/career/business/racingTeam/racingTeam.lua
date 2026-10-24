-- Racing team business facade: registers the team with the business manager and publishes its public API.
-- Read configuration/state, helpers, parts, ordered ticks, lifecycle, public topics and game hooks.
local M = {}

M.dependencies = {'overhaul_career_business_manager', 'overhaul_events_fre_state', 'overhaul_events_fre_sanctionedRacing', 'overhaul_career_business_racingTeam_rideAlong'}

-- Requires ----------------------------------------------------------------------------------------

local racingTeamBuildClass = require('overhaul/career/business/racingTeam/racingTeam/buildClass')
local racingTeamSponsors = require('overhaul/career/business/racingTeam/racingTeam/sponsors')
local racingTeamLeagueInvite = require('overhaul/career/business/racingTeam/racingTeam/leagueInvite')
local racingTeamRaceOffers = require('overhaul/career/business/racingTeam/racingTeam/raceOffers')
local racingTeamFleet = require('overhaul/career/business/racingTeam/racingTeam/fleet')
local racingTeamGoals = require('overhaul/career/business/racingTeam/racingTeam/goals')
require('overhaul/career/business/racingTeam/racingTeam/devLog')
local rtState = require('overhaul/career/business/racingTeam/racingTeam/runtimeState')

-- Config ------------------------------------------------------------------------------------------

local RACE_OFFER_BOARD_MAX_SLOTS = 4

-- State -------------------------------------------------------------------------------------------


-- Team vehicle sales waiting for their credit, shared by the racing team files (reset on activation).
local teamSales = {pendingTeamVehicleSales = {}}

-- Parts read siblings through this table after construction has finished.
local parts = {
  buildClass = racingTeamBuildClass, sponsors = racingTeamSponsors, leagueInvite = racingTeamLeagueInvite,
  raceOffers = racingTeamRaceOffers, fleet = racingTeamFleet, goals = racingTeamGoals,
}
local helpers = {}
parts.helpers = helpers
rtState.parts = parts

-- Other extensions --------------------------------------------------------------------------------

local function racingTeamFinances() return overhaul_career_business_racingTeam_finances end
local function racingTeamManager() return overhaul_career_business_racingTeam_manager end
-- BeamNG: read the global directly; extensions.get is not available here.
function helpers.raceFlowMod() return overhaul_career_business_racingTeam_raceFlow end

-- Shared helpers ----------------------------------------------------------------------------------

function helpers.normalizeBusinessId(businessId)
  return tonumber(businessId) or businessId
end

function helpers.rtDevLog(businessId, level, message, source, context)
  rtState.rtInternal.devLog.append(businessId, level, message, source, context)
end

function helpers.getSkillTreeNodeLevel(businessId, treeId, nodeId)
  if not businessId or not treeId or not nodeId then return 0 end
  local skillTree = overhaul_career_business_skillTree
  local level = skillTree.getNodeProgress(helpers.normalizeBusinessId(businessId), treeId, nodeId)
  return math.max(0, math.floor(tonumber(level) or 0))
end

function helpers.getRacingTeamGarageSlotsSkillLevel(businessId)
  return helpers.getSkillTreeNodeLevel(businessId, "qol", "garageSlots")
end

function helpers.getMaxRaceOffersOnBoard()
  return math.min(RACE_OFFER_BOARD_MAX_SLOTS, math.max(1, rtState.K.MAX_RACE_OFFERS_ON_BOARD))
end

function helpers.league2InvitePromoKey(businessId)
  return tostring(helpers.normalizeBusinessId(businessId))
end

function helpers.proxyPodiumXpFromMoney(money)
  return math.max(0, math.floor((tonumber(money) or 0) * rtState.K.PROXY_PODIUM_XP_OF_MONEY + 1e-9))
end

-- Race offer state of one business; loads its saved offers the first time it is read.
function helpers.getOfferState(businessId)
  local id = tostring(helpers.normalizeBusinessId(businessId))
  if not rtState.offerStateByBusiness[id] then
    rtState.offerStateByBusiness[id] = {
      active = {},
      new = {}
    }
  end
  if not rtState.persistLoaded[id] then
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if savePath then
      rtState.persistLoaded[id] = true
      parts.persist.loadRacingTeamPersistedState(businessId, rtState.offerStateByBusiness[id])
    end
  end
  return rtState.offerStateByBusiness[id]
end

-- Sale reset --------------------------------------------------------------------------------------

local function addLeaderboardId(ids, seen, identifier)
  if identifier and not seen[identifier] then
    seen[identifier] = true
    table.insert(ids, identifier)
  end
end

-- Leaderboard inventory ids of the fleet and jobs, read before the storage is cleared.
local function collectLeaderboardInventoryIds(bid, id)
  local ids, seen = {}, {}
  local fleet = overhaul_career_business_fleet
  do
    for _, vehicle in ipairs(fleet.getBusinessVehicles(bid) or {}) do
      local vehicleId = vehicle and (tonumber(vehicle.vehicleId) or vehicle.vehicleId)
      if vehicleId ~= nil then
        addLeaderboardId(ids, seen, fleet.getBusinessVehicleIdentifier(bid, vehicleId))
      end
      if vehicle and vehicle.jobId ~= nil then
        addLeaderboardId(ids, seen, fleet.getBusinessJobIdentifier(bid, vehicle.jobId))
      end
    end
  end
  do
    local offerState = rtState.offerStateByBusiness[id]
    if offerState and type(offerState.active) == "table" then
      for _, activeJob in ipairs(offerState.active) do
        if activeJob and activeJob.jobId ~= nil then
          addLeaderboardId(ids, seen, fleet.getBusinessJobIdentifier(bid, activeJob.jobId))
        end
        if activeJob and activeJob.storedVehicleId ~= nil then
          addLeaderboardId(ids, seen, fleet.getBusinessJobIdentifier(bid, activeJob.storedVehicleId))
        end
      end
    end
  end
  return ids
end

local function clearBusinessStorage(bid)
  overhaul_career_business_fleet.clearBusinessInventory(bid)
  overhaul_career_business_partInventory.clearBusinessParts(bid)
  overhaul_career_market_vehicleShopping.clearPendingRacingTeamFleetPurchases(bid)
end

local function clearLeaderboardInventories(inventoryIds)
  local leaderboards = overhaul_events_leaderboards
  if leaderboards and leaderboards.clearLeaderboardInventoriesBatchAtAllLevels and #inventoryIds > 0 then
    pcall(leaderboards.clearLeaderboardInventoriesBatchAtAllLevels, inventoryIds)
  end
end

-- Every per-business runtime table goes back to its career-start value.
local function resetBusinessRuntimeState(id, bid)
  rtState.offerStateByBusiness[id] = { new = {}, active = {} }
  rtState.goalCompletionByBusiness[id] = {}
  rtState.tuningMilestoneByBusiness[id] = nil
  rtState.tuningMilestoneByGoalByBusiness[id] = {}
  rtState.homeMechanicBaselinePwByBusiness[id] = nil
  rtState.pendingHomeMechanicPwRecheckByBusiness[id] = nil
  rtState.currentLeagueByBusiness[id] = "league1"
  rtState.offerJobIdCounters[id] = 0
  rtState.staminaShortTrackStreakByBusiness[id] = nil
  rtState.sanctionedOfficialFirstPlaceWinsByBusiness[id] = nil
  rtState.classOptimizationPeakHpByBusiness[id] = nil
  rtState.persistLoaded[id] = true
  rtState.vehicleCooldownByBusiness[id] = nil
  rtState.playerCooldownByBusiness[id] = nil
  rtState.allLeaderboardsBaselineByBusiness[id] = nil
  rtState.completedGoalLeaderboardTimesByBusiness[id] = nil
  rtState.raceOfferBoardByBusiness[id] = nil
  rtState.pendingRematchOfferByBusiness[id] = nil
  rtState.businessSkillXpByBusiness[id] = 0
  rtState.league2InviteByBusiness[id] = nil
  rtState.league2InvitePromoUiByBusiness[id] = nil
  rtState.purchaseMilestoneSplashShownByBusiness[id] = nil
  rtState.raceUnlockSplashPendingByBusiness[id] = nil
  rtState.raceUnlockSplashShownByBusiness[id] = nil
  rtState.careerFinaleSplashPendingByBusiness[id] = nil
  rtState.careerFinaleSplashShownByBusiness[id] = nil
  rtState.rtInternal.league2SplashQueued[id] = nil
  rtState.rtInternal.purchaseSplashQueued[id] = nil
  rtState.rtInternal.goalsPushToken[id] = nil
  rtState.rtInternal.sponsors[id] = nil
  rtState.businessDrivers[bid] = {}
end

local function clearBusinessTimers(bid)
  local proxyFlow = helpers.raceFlowMod()
  if proxyFlow and proxyFlow.clearProxyDriverRaceRequest then
    pcall(proxyFlow.clearProxyDriverRaceRequest, bid)
  end
  if racingTeamFinances() then
    racingTeamFinances().clearOperatingCostTimer(bid)
  end
  if racingTeamManager() then
    racingTeamManager().clearManagerTimer(bid)
  end
end

local function pushEmptyGoalsToComputer(bid)
  do
    guihooks.trigger("businessComputer:onRacingTeamGoals", {
      businessId = bid,
      currentGoal = nil,
      currentLeague = "league1",
      completedGoals = {},
      vehicles = {},
    })
  end
end

-- Sells the team: clears its fleet, parts, leaderboard entries and all per-business runtime state.
local function resetBusinessForSale(businessId)
  local bid = helpers.normalizeBusinessId(businessId)
  if not bid then return false end
  local id = tostring(bid)
  local leaderboardInventoryIds = collectLeaderboardInventoryIds(bid, id)
  clearBusinessStorage(bid)
  clearLeaderboardInventories(leaderboardInventoryIds)
  resetBusinessRuntimeState(id, bid)
  clearBusinessTimers(bid)
  pushEmptyGoalsToComputer(bid)
  return true
end

-- The business object the business manager reads for this team.
local businessObject = {
  businessType = rtState.businessType,
  features = {
    skillTrees = true,
    bankAccount = true,
    inventory = true,
    xpSystem = true,
  },
  getUIData = function(businessId) return rtState.rtInternal.getUIData(businessId) end,
  getDamageThreshold = function(businessId) return parts.fleet.getDamageThreshold(businessId) end,
  getMaxPulledOutVehicles = function(businessId) return parts.board.getMaxPulledOutVehicles(businessId) end,
  getMaxActiveJobs = function(businessId) return parts.board.getMaxActiveJobs(businessId) end,
  getBusinessXP = function(businessId) return parts.dispatch.getRacingTeamBusinessSkillXpValue(businessId) end,
  addBusinessXP = function(businessId, amount) return parts.dispatch.addRacingTeamBusinessSkillXpValue(businessId, amount) end,
  spendBusinessXP = function(businessId, amount) return parts.dispatch.spendRacingTeamBusinessSkillXpValue(businessId, amount) end,
  getLiquidationValue = function(businessId) return parts.ui.getLiquidationValue(businessId) end,
  resetBusinessForSale = function(businessId) return resetBusinessForSale(businessId) end,
  getTechsForBusiness = function(businessId) return parts.board.getRacingTeamDriversRawForUI(businessId) end,
  formatTechForUIEntry = function(businessId, tech) return parts.results.formatRacingTeamDriverForUI(businessId, tech) end,
}

-- Parts -------------------------------------------------------------------------------------------


-- Parts share one table and read each other at call time.
local serviceInputs = {
  persist = {
    rtState = rtState,
  },
  board = {
    racingTeamFleet = racingTeamFleet,
    rtState = rtState,
  },
  dispatch = {
    racingTeamFinances = racingTeamFinances,
    racingTeamGoals = racingTeamGoals,
    rtState = rtState,
  },
  results = {
    M = M,
    racingTeamFinances = racingTeamFinances,
    rtState = rtState,
  },
  jobs = {
    teamSales = teamSales,
    rtState = rtState,
  },
  ui = {
    racingTeamManager = racingTeamManager,
    racingTeamBuildClass = racingTeamBuildClass,
    rtState = rtState,
  },
}
for _, name in ipairs({"persist", "board", "dispatch", "results", "jobs", "ui"}) do
  serviceInputs[name].parts = parts
  parts[name] = require("overhaul/career/business/racingTeam/racingTeam/" .. name).new(serviceInputs[name])
end

-- Per-frame update --------------------------------------------------------------------------------

local function tickPostRaceCooldownDriverUiPushAccumulated(dtSim)
  if not dtSim or dtSim <= 0 then
    return
  end
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    return
  end
  local businessManager = overhaul_career_business_manager
  rtState.postRaceCooldownUiPollAccumulator = rtState.postRaceCooldownUiPollAccumulator + dtSim
  if rtState.postRaceCooldownUiPollAccumulator < rtState.K.POST_RACE_COOLDOWN_UI_POLL_INTERVAL_SIM then
    return
  end
  rtState.postRaceCooldownUiPollAccumulator = 0

  local purchased = businessManager.getPurchasedBusinesses(rtState.businessType) or {}
  local lastMap = rtState.rtInternal.lastPostRaceRemByTech or {}
  rtState.rtInternal.lastPostRaceRemByTech = lastMap

  for bid, _ in pairs(purchased) do
    local nb = helpers.normalizeBusinessId(bid)
    if nb then
      helpers.getOfferState(nb)
      rtState.loadRacingTeamDrivers(nb)
      local techs = rtState.businessDrivers[nb] or {}
      local anyTransition = false
      for _, tech in ipairs(techs) do
        if tech and tech.id and not tech.fired then
          local key = tostring(nb) .. "_" .. tostring(tech.id)
          local rem = parts.fleet.getRacingTeamDriverPostRaceCooldownRemainingSec(nb, tech)
          local prev = lastMap[key]
          if prev ~= nil and prev > 0 and rem <= 0 then
            anyTransition = true
          end
          lastMap[key] = rem > 0 and rem or 0
        end
      end
      if anyTransition then
        parts.results.racingTeamPersistDrivers(nb)
        parts.results.notifyRacingTeamDriversUpdated(nb)
      end
    end
  end
end

local function tickScheduledRaceReadyToastsAccumulated(dtSim)
  if not dtSim or dtSim <= 0 then
    return
  end
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    return
  end
  rtState.scheduledRaceReadyToastAccumulator = rtState.scheduledRaceReadyToastAccumulator + dtSim
  if rtState.scheduledRaceReadyToastAccumulator < rtState.K.SCHEDULED_RACE_READY_TOAST_INTERVAL then
    return
  end
  rtState.scheduledRaceReadyToastAccumulator = 0
  parts.dispatch.processScheduledRaceReadyToastQueue()
end

function M.tickRacingTeamManagerAccumulated(dtSim)
  if racingTeamManager() then
    racingTeamManager().tickAccumulated(dtSim)
  end
end

M.tickScheduledRaceReadyToastsAccumulated = tickScheduledRaceReadyToastsAccumulated
M.tickHomeMechanicPwDeferredRechecks = racingTeamGoals.tickHomeMechanicPwDeferredRechecks
M.tickPostRaceCooldownDriverUiPushAccumulated = tickPostRaceCooldownDriverUiPushAccumulated

-- Career lifecycle --------------------------------------------------------------------------------

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if not currentSavePath then
    return
  end
  local purchasedIds = {}
  for bid, _ in pairs((overhaul_career_business_manager
      and overhaul_career_business_manager.getPurchasedBusinesses(rtState.businessType)) or {}) do
    table.insert(purchasedIds, bid)
  end
  racingTeamFinances().saveOperatingCostTimers(currentSavePath, purchasedIds, writer)
  if racingTeamManager() then
    racingTeamManager().onOverhaulSaveCurrentProfile(currentSavePath, nil, writer)
  end
  local seen = {}
  local purchased = overhaul_career_business_manager
    and overhaul_career_business_manager.getPurchasedBusinesses(rtState.businessType)
  if purchased then
    for bid, _ in pairs(purchased) do
      helpers.getOfferState(bid)
      parts.persist.writeRacingTeamPersistedState(bid, currentSavePath, writer)
      rtState.loadRacingTeamDrivers(bid)
      parts.board.writeRacingTeamDrivers(bid, currentSavePath, writer)
      seen[tostring(helpers.normalizeBusinessId(bid))] = true
    end
  end
  for idStr, _ in pairs(rtState.offerStateByBusiness) do
    if not seen[idStr] then
      local bid = tonumber(idStr) or idStr
      parts.persist.writeRacingTeamPersistedState(bid, currentSavePath, writer)
      rtState.loadRacingTeamDrivers(bid)
      parts.board.writeRacingTeamDrivers(bid, currentSavePath, writer)
    end
  end
  require('overhaul/lib/business/saveState').clearUnownedFiles(currentSavePath,
    {"racingTeam.json", "racingDrivers.json", "racingTeamManager.json", "racingTeamShopOperatingCost.json"}, rtState.businessType, writer)
end

-- The race flow clears its proxy request first; the rest are career-start values for this team.
local function resetCareerRuntimeState()
  local proxyFlow = helpers.raceFlowMod()
  if proxyFlow and proxyFlow.onCareerActivated then
    proxyFlow.onCareerActivated()
  end
  teamSales.pendingTeamVehicleSales = {}
  rtState.scheduledRaceReadyToastAccumulator = 0
  rtState.offerStateByBusiness = {}
  rtState.goalCompletionByBusiness = {}
  rtState.tuningMilestoneByBusiness = {}
  rtState.tuningMilestoneByGoalByBusiness = {}
  rtState.homeMechanicBaselinePwByBusiness = {}
  rtState.pendingHomeMechanicPwRecheckByBusiness = {}
  rtState.currentLeagueByBusiness = {}
  rtState.offerJobIdCounters = {}
  rtState.persistLoaded = {}
  rtState.raceOfferBoardByBusiness = {}
  rtState.pendingRematchOfferByBusiness = {}
  rtState.businessSkillXpByBusiness = {}
  rtState.staminaShortTrackStreakByBusiness = {}
  rtState.sanctionedOfficialFirstPlaceWinsByBusiness = {}
  rtState.classOptimizationPeakHpByBusiness = {}
  rtState.businessDrivers = {}
  rtState.league2InviteByBusiness = {}
  rtState.league2InvitePromoUiByBusiness = {}
  rtState.purchaseMilestoneSplashShownByBusiness = {}
  rtState.raceUnlockSplashPendingByBusiness = {}
  rtState.raceUnlockSplashShownByBusiness = {}
  rtState.careerFinaleSplashPendingByBusiness = {}
  rtState.careerFinaleSplashShownByBusiness = {}
  rtState.rtInternal.league2SplashQueued = {}
  rtState.rtInternal.purchaseSplashQueued = {}
  rtState.rtInternal.careerFinaleSplashQueued = {}
  rtState.vehicleCooldownByBusiness = {}
  rtState.playerCooldownByBusiness = {}
  rtState.rtInternal.goalsPushToken = {}
  rtState.rtInternal.sponsors = {}
  rtState.rtInternal.racingTeamLevelInfoNormalizedCache = {}
  rtState.rtInternal.goalsDefinitionLoaded = false
  rtState.rtInternal.goalsDefinition = nil
  rtState.rtInternal.eligibleVehicleInfoByPair = nil
  rtState.rtInternal.lastPostRaceRemByTech = {}
  rtState.postRaceCooldownUiPollAccumulator = 0
  rtState.allLeaderboardsBaselineByBusiness = {}
  rtState.completedGoalLeaderboardTimesByBusiness = {}
end

-- Purchase and menu callbacks the business manager calls back into.
local function registerBusinessCallbacks()
  overhaul_career_business_manager.registerBusinessCallback(rtState.businessType, {
    onPurchase = function(businessId)
      local accountId = "business_" .. rtState.businessType .. "_" .. tostring(businessId)
      local capitalInjectionAmount = overhaul_career_business_manager.getPurchaseCapitalInjectionAmount(0)
      if capitalInjectionAmount > 0 then
        overhaul_career_economy_bank.rewardToAccount({
          money = { amount = capitalInjectionAmount }
        }, accountId, "Capital Injection", "Initial operating capital", {category = "business"})
      end
      helpers.getOfferState(businessId)
      rtState.rtInternal.schedulePurchaseMilestoneSplash(businessId)
      overhaul_career_saveSystem.saveCurrent()
    end,
    onMenuOpen = function(businessId)
      racingTeamBuildClass.warmupCatalogBaselines()
      parts.ui.openMenu(businessId)
    end
  })
end

local function onCareerActivated()
  resetCareerRuntimeState()
  racingTeamFinances().onCareerActivated()
  if racingTeamManager() then
    racingTeamManager().onCareerActivated()
  end
  overhaul_career_business_manager.registerBusiness(rtState.businessType, businessObject, M)
  parts.board.ensureTabsRegistered()
  registerBusinessCallbacks()
end

-- Public API: status and goals --------------------------------------------------------------------

-- Return a copy so reference screens cannot mutate the board's cached level policy.
function M.getLevelInfo(levelId)
  return deepcopy(parts.board.getRacingTeamLevelInfo(levelId))
end

M.getUIData = rtState.rtInternal.getUIData
M.getCurrentLeague = rtState.rtInternal.getCurrentLeague
M.isLeagueAtLeast = rtState.rtInternal.isLeagueAtLeast
M.isCurrentLeagueAtLeast = rtState.rtInternal.isCurrentLeagueAtLeast
M.getBusinessXP = parts.dispatch.getRacingTeamBusinessSkillXpValue
M.addBusinessXP = parts.dispatch.addRacingTeamBusinessSkillXpValue
M.spendBusinessXP = parts.dispatch.spendRacingTeamBusinessSkillXpValue
M.getMaxPulledOutVehicles = parts.board.getMaxPulledOutVehicles
M.getMaxActiveJobs = parts.board.getMaxActiveJobs
M.formatVehicleForUI = function(vehicle, businessId) return rtState.formatVehicleForUI(vehicle, businessId) end

function M.getCareerSimTimeForUI()
  return parts.board.getCareerSimTimeSeconds()
end

-- The goals are prepared from saved state before the pure projection reads them.
function M.getActiveGoals(businessId)
  helpers.getOfferState(businessId)
  rtState.rtInternal.prepareActiveGoalData(businessId)
  local rows = parts.goals.getActiveList(businessId)
  return rows
end

M.getCompletedGoals = parts.goals.getCompletedList

-- Public API: fleet, jobs and sales ---------------------------------------------------------------

M.getActiveJobs = parts.jobs.getActiveJobs
M.getNewJobs = parts.jobs.getNewJobs
M.acceptJob = parts.jobs.acceptJob
M.declineJob = parts.jobs.declineJob
M.abandonJob = parts.jobs.abandonJob
M.sellVehicle = parts.jobs.sellVehicle
M.armFleetVehicleCooldownAfterSanctionedRaceSettled = function(offer)
  return racingTeamFleet.armFleetVehicleCooldownAfterSanctionedRaceSettled(offer)
end
M.sanctionedOfferMatchesFleetVehicle = parts.board.sanctionedOfferMatchesFleetVehicle
M.fleetVehicleOverpoweredForOffer = parts.board.fleetVehicleOverpoweredForOffer
M.fleetVehicleEligibleForOffer = parts.board.fleetVehicleEligibleForOffer
M.assignJobToTech = parts.results.assignJobToTech
M.assignFleetVehicleToDriver = parts.results.assignFleetVehicleToDriver
M.updateTechName = parts.results.updateTechName
M.fireTech = parts.results.fireTech
M.hireTech = parts.results.hireTech
M.stopTechFromJob = parts.results.stopTechFromJob
M.acceptRacingTeamSponsorOffer = parts.sponsors.acceptOffer
M.declineRacingTeamSponsorOffer = parts.sponsors.declineOffer
M.dropRacingTeamSponsorActive = parts.sponsors.dropActive
M.requestFinancesData = function(...) return racingTeamFinances().requestFinancesData(...) end
M.getRacingTeamPostRaceCooldownSeconds = parts.fleet.getRacingTeamPostRaceCooldownSeconds
M.getRacingTeamDriverPostRaceCooldownRemainingSec = parts.fleet.getRacingTeamDriverPostRaceCooldownRemainingSec
M.ensureSanctionedRaceOffersBoard = parts.raceOffers.ensureBoard
M.getFleetVehiclePostRaceCooldownRemainingSec = parts.fleet.getFleetVehiclePostRaceCooldownRemainingSec
M.getPlayerPostRaceCooldownRemainingSec = parts.fleet.getPlayerPostRaceCooldownRemainingSec
M.armPlayerPostRaceCooldown = parts.fleet.armPlayerPostRaceCooldown
M.getRacingTeamPlayerPostRaceCooldownSeconds = parts.fleet.getRacingTeamPlayerPostRaceCooldownSeconds

function M.applySanctionedRaceDriverCutFromBusinessPayout(businessId, grossAmount, opts)
  racingTeamFinances().applyDriverCutAfterPayout(businessId, grossAmount, opts or {})
end

-- Share of a sanctioned race's gross the team keeps when the player drove it instead of a hired driver.
function M.getPlayerRacePayoutMultiplier()
  return rtState.K.RACING_TEAM_PLAYER_RACE_PAYOUT_MULTIPLIER
end

-- Public API: race offers and proxy races ---------------------------------------------------------

M.acceptRacingTeamRaceOffer = parts.dispatch.acceptRacingTeamRaceOffer
M.acceptRacingTeamRaceOfferAsPlayer = parts.dispatch.acceptRacingTeamRaceOfferAsPlayer
M.listLeague1FleetVehiclesForSanctionedOffer = parts.dispatch.listLeague1FleetVehiclesForSanctionedOffer
M.listLeague2FleetVehiclesForSanctionedOffer = parts.dispatch.listLeague2FleetVehiclesForSanctionedOffer
M.acceptRacingTeamRaceOfferAsPlayerAlongsideProxy = parts.dispatch.acceptRacingTeamRaceOfferAsPlayerAlongsideProxy
M.declineRacingTeamRaceOffer = parts.dispatch.declineRacingTeamRaceOffer
M.isScheduledRaceReadyForDriver = parts.dispatch.isScheduledRaceReadyForDriver
M.assignRolledProxyRaceToDriver = parts.dispatch.assignRolledProxyRaceToDriver
M.clearProxyDriverRaceRequest = parts.dispatch.clearProxyDriverRaceRequest
M.getProxyDriverRaceRequest = parts.dispatch.getProxyDriverRaceRequest
M.clearRacingTeamProxyDriverAssignment = parts.results.clearRacingTeamProxyDriverAssignment
M.cancelUnarmedScheduledRacingTeamProxyRace = parts.results.cancelUnarmedScheduledRacingTeamProxyRace
M.clearStuckRacingTeamProxyAfterTrackRaceCompletion = parts.results.clearStuckRacingTeamProxyAfterTrackRaceCompletion
M.findProxyDriverRaceRequestForLevel = parts.results.findProxyDriverRaceRequestForLevel
M.settleProxySanctionedRaceFromAiResults = parts.results.settleProxySanctionedRaceFromAiResults
M.onBusinessSanctionedRaceOutcome = parts.results.onBusinessSanctionedRaceOutcome
M.getProxyDriverAiDifficultyBlendT = function(businessId, driverId)
  businessId = helpers.normalizeBusinessId(businessId)
  driverId = tonumber(driverId)
  if not businessId or not driverId then
    return 1
  end
  helpers.getOfferState(businessId)
  local tech = parts.board.getRacingTeamDriverById(businessId, driverId)
  if not tech or tech.fired then
    return 1
  end
  return parts.dispatch.proxyDriverAiDifficultyBlendTFromXp(tech.racingSkillXp)
end

M.requestProxyDriverRace = function(opts)
  local flow = helpers.raceFlowMod()
  if flow and flow.requestProxyDriverRace then
    return flow.requestProxyDriverRace(opts)
  end
  return { ok = false, err = "no_proxy_flow" }
end

-- Checks a proxy race request against the driver, fleet and offer; returns the driver, or nil and the refusal.
local function proxyRaceDriverRefusal(businessId, driverId)
  helpers.getOfferState(businessId)
  local tech = parts.board.getRacingTeamDriverById(businessId, driverId)
  if not tech or tech.fired then
    return nil, "invalid_driver"
  end
  if not tech.pendingRaceOffer then
    return nil, "no_pending_race_offer"
  end
  if not parts.dispatch.isScheduledRaceReadyForDriver(businessId, driverId) then
    return nil, "race_not_scheduled_yet"
  end
  local fleetVehicleId = tech.fleetVehicleId
  if not fleetVehicleId or not parts.board.getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId) then
    return nil, "no_valid_fleet_vehicle"
  end
  local pendingRace = tech.pendingRaceOffer
  if parts.board.fleetVehicleOverpoweredForOffer(businessId, fleetVehicleId, pendingRace) then
    return nil, "fleet_hp_over_class_max"
  end
  if not parts.board.fleetVehicleEligibleForOffer(businessId, fleetVehicleId, pendingRace) then
    return nil, "fleet_hp_bracket_mismatch"
  end
  return tech
end

-- Copies the offer, so the stored request cannot change when the board's offer does.
local function copyOfferSnapshot(offer)
  local snapshot = {}
  for k, v in pairs(offer) do
    snapshot[k] = v
  end
  return snapshot
end

function M.proxyDriverRaceValidateAndBuildRequest(opts)
  if type(opts) ~= "table" then
    return { ok = false, err = "invalid_opts" }
  end
  local businessId = helpers.normalizeBusinessId(opts.businessId)
  local driverId = tonumber(opts.driverId)
  if not businessId or not driverId then
    return { ok = false, err = "missing_business_or_driver" }
  end
  local tech, refusal = proxyRaceDriverRefusal(businessId, driverId)
  if not tech then
    return { ok = false, err = refusal }
  end
  local fleetVehicleId = tech.fleetVehicleId
  local pendingRace = tech.pendingRaceOffer
  local board = parts.raceOffers.getBoard(businessId)
  local levelId = (board and board.levelId) or parts.board.getRacingTeamLevelId() or ""
  local id = tostring(helpers.normalizeBusinessId(businessId))
  local out = {
    racingTeamProxyRace = true,
    businessId = id,
    driverId = driverId,
    fleetVehicleId = tonumber(fleetVehicleId) or fleetVehicleId,
    offerId = pendingRace.id,
    offerSnapshot = copyOfferSnapshot(pendingRace),
    levelId = levelId,
    raceName = pendingRace.raceName,
    raceLabel = pendingRace.raceLabel,
    raceRouteType = pendingRace.raceRouteType,
    lapCount = tonumber(pendingRace.lapCount),
    stageNumber = tonumber(pendingRace.stageNumber),
    hpBracketLabel = pendingRace.hpBracketLabel,
    requestedAtSimTime = parts.board.getCareerSimTime(),
  }
  return { ok = true, businessId = businessId, request = out }
end

function M.persistRacingTeamBusinessJson(businessId)
  businessId = helpers.normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if savePath then
    helpers.getOfferState(businessId)
    parts.persist.saveRacingTeamPersistedState(businessId, savePath)
  end
  overhaul_career_saveSystem.saveCurrent()
end

function M.isProxyScheduledDriverFleetOverpowered(businessId, driverId)
  businessId = helpers.normalizeBusinessId(businessId)
  driverId = tonumber(driverId)
  if not businessId or not driverId then
    return { overpowered = false }
  end
  local tech = parts.board.getRacingTeamDriverById(businessId, driverId)
  if not tech or tech.fired or type(tech.pendingRaceOffer) ~= "table" then
    return { overpowered = false }
  end
  if tech.fleetVehicleId == nil then
    return { overpowered = false }
  end
  local pendingRace = tech.pendingRaceOffer
  local fid = tonumber(tech.fleetVehicleId) or tech.fleetVehicleId
  if parts.board.fleetVehicleOverpoweredForOffer(businessId, fid, pendingRace) then
    return { overpowered = true }
  end
  return { overpowered = false }
end

function M.isArmedProxyFleetOverpoweredForRequest(businessId)
  businessId = helpers.normalizeBusinessId(businessId)
  if not businessId then
    return { overpowered = false }
  end
  local req = parts.dispatch.getProxyDriverRaceRequest(businessId)
  local offer = req and type(req.offerSnapshot) == "table" and req.offerSnapshot
  if not offer or not req or req.fleetVehicleId == nil then
    return { overpowered = false }
  end
  local fid = tonumber(req.fleetVehicleId) or req.fleetVehicleId
  if parts.board.fleetVehicleOverpoweredForOffer(businessId, fid, offer) then
    return { overpowered = true }
  end
  return { overpowered = false }
end

-- Public API: league invites, milestones and staff settings ---------------------------------------

M.acceptLeague2Invite = parts.leagueInvite.accept
M.declineLeague2Invite = parts.leagueInvite.decline
M.racingTeamMilestoneLeague2Later = parts.leagueInvite.milestoneLeague2Later
M.racingTeamMilestoneLeague2Accept = parts.leagueInvite.milestoneLeague2Accept
M.racingTeamMilestoneLeague2WelcomeContinue = parts.leagueInvite.milestoneLeague2WelcomeContinue
M.racingTeamMilestonePurchaseContinue = parts.leagueInvite.milestonePurchaseContinue
M.racingTeamMilestoneCareerFinaleContinue = parts.leagueInvite.milestoneCareerFinaleContinue

function M.setRacingTeamManagerAutoAssign(businessId, enabled)
  if racingTeamManager() then
    return racingTeamManager().setManagerAutoAssignEnabled(businessId, enabled)
  end
  return false
end

function M.setRacingTeamManagerAssignInterval(businessId, intervalSec)
  if racingTeamManager() then
    return racingTeamManager().setManagerAssignIntervalSec(businessId, intervalSec)
  end
  return false
end

M.notifyBusinessVehiclePartsPurchased = racingTeamGoals.notifyBusinessVehiclePartsPurchased
M.notifyTeamVehicleDynoPeakHp = racingTeamGoals.notifyTeamVehicleDynoPeakHp
M.notifyShortTrackStaminaLap = racingTeamGoals.notifyShortTrackStaminaLap
M.onOverhaulRaceResult = racingTeamGoals.notifyShortTrackStaminaLap
M.notifyOfficialSanctionedPodium = racingTeamGoals.notifyOfficialSanctionedPodium

function M.notifyFleetFromShop(businessId)
  racingTeamBuildClass.warmupCatalogBaselines()
  rtState.rtInternal.advanceRacingTeamGoalsIfReady(businessId)
  rtState.rtInternal.pushRacingTeamGoalsToBusinessComputer(businessId)
  overhaul_career_saveSystem.saveCurrent()
end

-- Phone ready toasts: a pending race is ready once its sim or wall-clock due time has passed.
local function isPendingRaceReadyDue(pending)
  if not pending then
    return false
  end
  local simDue = tonumber(pending.scheduledRaceSimTime)
  local wallDue = tonumber(pending.scheduledRaceReadyWallEpoch)
  local simReady = not simDue or parts.board.getCareerSimTimeSeconds() >= simDue
  local wallReady = wallDue and os.time() >= wallDue
  return simReady or wallReady
end

function M.notifyOnPhoneAppInstalled()
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    return
  end
  local purchased = overhaul_career_business_manager.getPurchasedBusinesses(rtState.businessType)
  if not purchased then
    return
  end
  for bid, _ in pairs(purchased) do
    local businessId = helpers.normalizeBusinessId(bid)
    local changed = false
    for _, tech in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
      local pending = tech.pendingRaceOffer
      if pending and isPendingRaceReadyDue(pending) and pending.raceReadyToastSent then
        pending.raceReadyToastSent = false
        changed = true
      end
    end
    if changed then
      parts.results.racingTeamPersistDrivers(businessId)
      parts.results.notifyRacingTeamDriversUpdated(businessId)
    end
  end
  parts.dispatch.processScheduledRaceReadyToastQueue()
end

function M.tickScheduledRaceReadyToasts()
  parts.dispatch.processScheduledRaceReadyToastQueue()
end



-- Dev console tools the business computer calls; the computer reaches them here, never through devConsole.lua.
local devConsole = require('overhaul/career/business/racingTeam/racingTeam/devConsole')
M.devConsoleClearCooldowns = devConsole.clearCooldowns
M.devConsoleRefreshRaceOffers = devConsole.refreshRaceOffers
M.devConsoleForceLeagueInvite = devConsole.forceLeagueInvite
M.devConsoleCompleteCurrentGoal = devConsole.completeCurrentGoal
M.devConsoleCompleteAllLeagueGoals = devConsole.completeAllLeagueGoals
M.devConsoleResetCurrentLeagueGoals = devConsole.resetCurrentLeagueGoals
M.devConsoleMaxAllSkills = devConsole.maxAllSkills
M.devConsoleGetDevLog = devConsole.getDevLog
M.devConsoleClearDevLog = devConsole.clearDevLog
M.devConsoleResetBusiness = devConsole.resetBusiness
M.devConsoleResetBusinessSoft = devConsole.resetBusinessSoft
M.devConsoleResetBusinessHard = devConsole.resetBusinessHard
M.devConsoleInjectXp = devConsole.injectXp
M.devConsoleInjectMoney = devConsole.injectMoney

-- Game hooks --------------------------------------------------------------------------------------

M.onCareerActivated = onCareerActivated
M.onOverhaulActive = function(active) if not active then racingTeamLeagueInvite.releaseMilestonePause() end end
M.onExtensionUnloaded = racingTeamLeagueInvite.releaseMilestonePause
M.onOverhaulBeforeSetProfile = racingTeamLeagueInvite.releaseMilestonePause
M.racingTeamMilestoneSplashOpen = racingTeamLeagueInvite.setMilestoneSplashOpen
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.refreshDevConsoleTab = parts.board.ensureTabsRegistered

function M.onOverhaulCareerSimStep(dtSim)
  M.tickPostRaceCooldownDriverUiPushAccumulated(dtSim)
  M.tickHomeMechanicPwDeferredRechecks()
  M.tickScheduledRaceReadyToastsAccumulated(dtSim)
  M.tickRacingTeamManagerAccumulated(dtSim)
  -- Finances run after every team tick, and resolve live so a career reload never reuses a stale module.
  local finances = overhaul_career_business_racingTeam_finances
  if finances then
    finances.onCareerSimStep(dtSim)
  end
end

-- Computer actions and activity take the finished module, so they load last.
M.actions = require("overhaul/career/business/racingTeam/racingTeam/computerActions")(M, helpers.raceFlowMod)

M.activity = require('overhaul/career/business/racingTeam/racingTeam/activity')(M)
return M
