-- Racing team development actions, gated by the live developer console.
-- Read dependencies, guards, diagnostics, offers, goals, skills, resets and account actions.
local capabilities = require("overhaul/lib/platform/capabilities")
local M = {}

-- Requires ----------------------------------------------------------------------------------------

local devLogModule = require("overhaul/career/business/racingTeam/racingTeam/devLog")
local rtState = require("overhaul/career/business/racingTeam/racingTeam/runtimeState")
local racingTeamGoals = require("overhaul/career/business/racingTeam/racingTeam/goals")
local racingTeamLeagueInvite = require("overhaul/career/business/racingTeam/racingTeam/leagueInvite")
local racingTeamRaceOffers = require("overhaul/career/business/racingTeam/racingTeam/raceOffers")
local function racingTeamManager() return overhaul_career_business_racingTeam_manager end

-- Config ------------------------------------------------------------------------------------------

local BUSINESS_TYPE = "racingTeam"
local INJECT_MONEY_AMOUNT = 1000000
local INJECT_XP_AMOUNT = 20000

-- Shared helpers ----------------------------------------------------------------------------------

local function logDev(businessId, level, message, source, context)
  devLogModule.append(businessId, level, message, source, context)
end

local function normalizeBusinessId(businessId)
  return tonumber(businessId) or businessId
end

local function ensureOfferState(businessId)
  return rtState.parts.helpers.getOfferState(businessId)
end

local function guard()
  return devLogModule.requireEnabled()
end

local function refreshUi(businessId)
  rtState.rtInternal.pushRacingTeamGoalsToBusinessComputer(businessId)
  overhaul_career_saveSystem.saveCurrent()
end

local function getHeadGoalId(businessId)
  local def = racingTeamGoals.loadDefinition()
  local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
  local leagueGoals = racingTeamGoals.getSortedForLeague(def, leagueId)
  for _, g in ipairs(leagueGoals or {}) do
    if g and g.id and not racingTeamGoals.idCompleted(businessId, g.id) then
      return g.id
    end
  end
  return nil
end

local function skipDriverSchedulingWaits(tech)
  if type(tech) ~= "table" then
    return false
  end
  tech.racingCooldownUntilSimTime = nil
  tech.postRaceCooldownReadyWallEpoch = nil
  local pr = tech.pendingRaceOffer
  if type(pr) ~= "table" then
    return false
  end
  local nowSim = rtState.parts.board.getCareerSimTimeSeconds() or 0
  pr.scheduledRaceSimTime = nowSim - 1
  pr.scheduledRaceReadyWallEpoch = os.time() - 1
  pr.raceReadyToastSent = false
  return true
end

-- Diagnostics -------------------------------------------------------------------------------------

function M.getDevLog(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if businessId then
    devLogModule.scanIssues(businessId)
  end
  return { ok = true, lines = devLogModule.getFormattedLines() }
end

function M.clearDevLog()
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  devLogModule.clear()
  return { ok = true }
end

-- Cooldowns and offers ----------------------------------------------------------------------------

function M.clearCooldowns(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  local id = tostring(businessId)
  rtState.vehicleCooldownByBusiness[id] = {}
  rtState.playerCooldownByBusiness[id] = nil
  ensureOfferState(businessId)
  local scheduledReady = 0
  if rtState.businessDrivers[businessId] then
    for _, tech in ipairs(rtState.businessDrivers[businessId]) do
      if skipDriverSchedulingWaits(tech) then
        scheduledReady = scheduledReady + 1
      end
    end
  end
  local board = rtState.parts.raceOffers.getBoard(businessId)
  if board then
    board.nextRefreshAt = 0
  end
  if racingTeamManager() then
    racingTeamManager().devSkipAssignWait(businessId)
  end
  if overhaul_career_career and overhaul_career_career.isActive() then
    pcall(overhaul_career_business_racingTeam_racingTeam.tickScheduledRaceReadyToasts)
  end
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if savePath then
    rtState.parts.persist.saveRacingTeamPersistedState(businessId, savePath)
  end
  logDev(
    businessId,
    "info",
    string.format(
      "Skipped waits (cooldowns, %d scheduled race(s), manager booking timer, offer refresh)",
      scheduledReady
    ),
    "devConsole"
  )
  refreshUi(businessId)
  return { ok = true, scheduledReady = scheduledReady }
end

function M.refreshRaceOffers(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  local board = rtState.parts.raceOffers.getBoard(businessId)
  if board then
    board.nextRefreshAt = 0
  end
  racingTeamRaceOffers.topUp(businessId)
  logDev(businessId, "info", "Refreshed race offers", "devConsole")
  refreshUi(businessId)
  return { ok = true }
end

function M.forceLeagueInvite(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  ensureOfferState(businessId)
  local currentLeague = rtState.rtInternal.getCurrentLeague(businessId)
  local nextLeague = rtState.rtInternal.getNextLeagueForPromotion(currentLeague)
  if not nextLeague then
    logDev(businessId, "warn", "Force league invite: no next league", "devConsole")
    return { ok = false, error = "no_next_league" }
  end
  local inv = racingTeamLeagueInvite.getInviteTable(businessId)
  inv.offeredAt = rtState.parts.board.getCareerSimTime()
  inv.targetLeague = nextLeague
  inv.declined = false
  rtState.league2InvitePromoUiByBusiness[tostring(businessId)] = "splash"
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if savePath then
    rtState.parts.persist.saveRacingTeamPersistedState(businessId, savePath)
  end
  logDev(businessId, "info", "Forced league invite to " .. tostring(nextLeague), "devConsole")
  refreshUi(businessId)
  return { ok = true }
end

function M.completeCurrentGoal(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  local goalId = getHeadGoalId(businessId)
  if not goalId then
    logDev(businessId, "warn", "Complete current goal: none active", "devConsole")
    return { ok = false, error = "no_active_goal" }
  end
  racingTeamGoals.markGoalCompleted(businessId, goalId)
  logDev(businessId, "info", "Dev-completed goal " .. tostring(goalId), "devConsole")
  refreshUi(businessId)
  return { ok = true, goalId = goalId }
end

-- Goals -------------------------------------------------------------------------------------------

function M.completeAllLeagueGoals(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  local def = racingTeamGoals.loadDefinition()
  local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
  local leagueGoals = racingTeamGoals.getSortedForLeague(def, leagueId)
  local count = 0
  for _, g in ipairs(leagueGoals or {}) do
    if g and g.id and not racingTeamGoals.idCompleted(businessId, g.id) then
      racingTeamGoals.markGoalCompleted(businessId, g.id)
      count = count + 1
    end
  end
  logDev(businessId, "info", "Dev-completed " .. tostring(count) .. " league goals", "devConsole")
  refreshUi(businessId)
  return { ok = true, count = count }
end

local function clearLeagueGoalRecords(id, leagueGoals)
  rtState.goalCompletionByBusiness[id] = rtState.goalCompletionByBusiness[id] or {}
  rtState.tuningMilestoneByGoalByBusiness[id] = rtState.tuningMilestoneByGoalByBusiness[id] or {}
  local cleared = 0
  local firstGoalId = nil
  for _, g in ipairs(leagueGoals) do
    if g and g.id then
      if not firstGoalId then
        firstGoalId = g.id
      end
      if rtState.goalCompletionByBusiness[id][g.id] then
        rtState.goalCompletionByBusiness[id][g.id] = nil
        cleared = cleared + 1
      end
      rtState.tuningMilestoneByGoalByBusiness[id][g.id] = nil
      if rtState.completedGoalLeaderboardTimesByBusiness[id] then
        rtState.completedGoalLeaderboardTimesByBusiness[id][g.id] = nil
      end
    end
  end
  if next(rtState.tuningMilestoneByGoalByBusiness[id]) == nil then
    rtState.tuningMilestoneByBusiness[id] = nil
  else
    rtState.tuningMilestoneByBusiness[id] = true
  end

  return cleared, firstGoalId
end

local function resetLeaguePromotion(businessId, id, leagueId)
  local nextLeague = rtState.rtInternal.getNextLeagueForPromotion(leagueId)
  if nextLeague then
    local inv = racingTeamLeagueInvite.getInviteTable(businessId)
    if inv.targetLeague == nextLeague then
      inv.offeredAt = nil
      inv.declined = false
      inv.targetLeague = nil
      rtState.league2InvitePromoUiByBusiness[id] = nil
    end
  end

  if leagueId == "league4" then
    rtState.careerFinaleSplashPendingByBusiness[id] = nil
    rtState.careerFinaleSplashShownByBusiness[id] = nil
    if rtState.rtInternal.careerFinaleSplashQueued then
      rtState.rtInternal.careerFinaleSplashQueued[id] = nil
    end
  end
end

function M.resetCurrentLeagueGoals(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  ensureOfferState(businessId)
  local id = tostring(businessId)
  local def = racingTeamGoals.loadDefinition()
  local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
  local leagueGoals = racingTeamGoals.getSortedForLeague(def, leagueId)
  if not leagueGoals or #leagueGoals == 0 then
    logDev(businessId, "warn", "Reset current league: no goals for " .. tostring(leagueId), "devConsole")
    return { ok = false, error = "no_league_goals" }
  end

  local cleared, firstGoalId = clearLeagueGoalRecords(id, leagueGoals)
  resetLeaguePromotion(businessId, id, leagueId)

  rtState.rtInternal.refreshLeague2InviteOffer(businessId)
  rtState.parts.results.syncRacingTeamDriverUnlock(businessId)
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if savePath then
    rtState.parts.persist.saveRacingTeamPersistedState(businessId, savePath)
  end
  logDev(
    businessId,
    "warn",
    string.format("Reset %s: cleared %d goal(s), active head %s", tostring(leagueId), cleared, tostring(firstGoalId)),
    "devConsole"
  )
  refreshUi(businessId)
  return { ok = true, leagueId = leagueId, cleared = cleared, firstGoalId = firstGoalId }
end

-- Skills ------------------------------------------------------------------------------------------

function M.maxAllSkills(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  local st = overhaul_career_business_skillTree
  st.debugMaxAllNodes(BUSINESS_TYPE, businessId)
  logDev(businessId, "info", "Unlocked all skill nodes", "devConsole")
  refreshUi(businessId)
  return { ok = true }
end

local function resetBusinessBankToPurchaseState(businessId)
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    return false, "bank_unavailable"
  end
  local account = overhaul_career_economy_bank.getBusinessAccount(BUSINESS_TYPE, businessId)
  local accountId = account and (account.id or account.accountId)
  if not accountId then
    return false, "no_account"
  end
  local balance = math.floor(tonumber(account.balance) or 0)
  if balance > 0 then
    overhaul_career_economy_bank.removeFunds(accountId, balance, "Dev Console", "Hard reset bank wipe", nil, {category = "cheat"})
  end
  local capitalInjectionAmount = overhaul_career_business_manager.getPurchaseCapitalInjectionAmount(0)
  if capitalInjectionAmount > 0 then
    overhaul_career_economy_bank.rewardToAccount({
      money = { amount = capitalInjectionAmount }
    }, accountId, "Dev Console", "Hard reset capital injection", {category = "cheat"})
  end
  return true
end

local function applySoftBusinessReset(businessId)
  local id = tostring(businessId)
  ensureOfferState(businessId)

  rtState.goalCompletionByBusiness[id] = {}
  rtState.tuningMilestoneByBusiness[id] = nil
  rtState.tuningMilestoneByGoalByBusiness[id] = {}
  rtState.homeMechanicBaselinePwByBusiness[id] = nil
  rtState.pendingHomeMechanicPwRecheckByBusiness[id] = nil
  rtState.allLeaderboardsBaselineByBusiness[id] = nil
  rtState.completedGoalLeaderboardTimesByBusiness[id] = nil
  rtState.staminaShortTrackStreakByBusiness[id] = nil
  rtState.sanctionedOfficialFirstPlaceWinsByBusiness[id] = nil

  rtState.currentLeagueByBusiness[id] = "league1"
  rtState.league2InviteByBusiness[id] = nil
  rtState.league2InvitePromoUiByBusiness[id] = nil
  rtState.raceUnlockSplashPendingByBusiness[id] = nil
  rtState.raceUnlockSplashShownByBusiness[id] = nil
  rtState.raceOfferBoardByBusiness[id] = nil
  rtState.pendingRematchOfferByBusiness[id] = nil

  local st = overhaul_career_business_skillTree
  st.clearBusinessProgress(businessId)

  local board = rtState.parts.raceOffers.getBoard(businessId)
  if board then
    board.nextRefreshAt = 0
  end
  racingTeamRaceOffers.topUp(businessId)
end

function M.resetBusinessSoft(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  applySoftBusinessReset(businessId)
  logDev(businessId, "warn", "Soft reset: goals, league, and skills (fleet and bank kept)", "devConsole")
  refreshUi(businessId)
  return { ok = true }
end

function M.resetBusinessHard(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  local businessObj = overhaul_career_business_manager
    and overhaul_career_business_manager.getBusinessObject(BUSINESS_TYPE)
  if not businessObj or not businessObj.resetBusinessForSale then
    return { ok = false, error = "reset_unavailable" }
  end
  if not businessObj.resetBusinessForSale(businessId) then
    return { ok = false, error = "reset_failed" }
  end
  local st = overhaul_career_business_skillTree
  st.clearBusinessProgress(businessId)
  local bankOk, bankErr = resetBusinessBankToPurchaseState(businessId)
  if not bankOk then
    logDev(businessId, "error", "Hard reset bank: " .. tostring(bankErr), "devConsole")
    return { ok = false, error = bankErr }
  end
  rtState.parts.board.ensureRacingTeamDriverSlots(businessId)
  rtState.rtInternal.schedulePurchaseMilestoneSplash(businessId)
  if overhaul_career_career and overhaul_career_career.isActive() then
    local computer = capabilities.peek("businessComputer")
    if computer then computer.clearBusinessContext(businessId) end
  end
  local board = rtState.parts.raceOffers.getBoard(businessId)
  if board then
    board.nextRefreshAt = 0
  end
  racingTeamRaceOffers.topUp(businessId)
  logDev(businessId, "warn", "Hard reset: fleet, drivers, bank, goals, and skills wiped", "devConsole")
  refreshUi(businessId)
  return { ok = true }
end

function M.resetBusiness(businessId)
  return M.resetBusinessSoft(businessId)
end

function M.injectXp(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  local businessObj = overhaul_career_business_manager
    and overhaul_career_business_manager.getBusinessObject(BUSINESS_TYPE)
  if not businessObj or not businessObj.addBusinessXP then
    return { ok = false, error = "xp_unavailable" }
  end
  businessObj.addBusinessXP(businessId, INJECT_XP_AMOUNT)
  logDev(businessId, "info", "Injected " .. tostring(INJECT_XP_AMOUNT) .. " skill XP", "devConsole")
  do
    guihooks.trigger("businessSkillTree:onTreesUpdated", { businessId = businessId })
  end
  refreshUi(businessId)
  return { ok = true, amount = INJECT_XP_AMOUNT }
end

function M.injectMoney(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    return { ok = false, error = "bank_unavailable" }
  end
  local account = overhaul_career_economy_bank.getBusinessAccount(BUSINESS_TYPE, businessId)
  local accountId = account and (account.id or account.accountId)
  if not accountId then
    return { ok = false, error = "no_account" }
  end
  local credited = overhaul_career_economy_bank.rewardToAccount({
    money = { amount = INJECT_MONEY_AMOUNT }
  }, accountId, "Dev Console", "Inject money", {category = "cheat"})
  if not credited then
    logDev(businessId, "error", "Inject money failed", "devConsole")
    return { ok = false, error = "credit_failed" }
  end
  logDev(businessId, "info", "Injected $" .. tostring(INJECT_MONEY_AMOUNT), "devConsole")
  overhaul_career_saveSystem.saveCurrent()
  return { ok = true }
end

return M
