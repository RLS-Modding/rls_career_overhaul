-- Racing team runtime state: per-business maps, tuning constants and the factory car list.
-- Every part of the team reads and writes these tables; M.K holds the tuning values and rtInternal the hooks.
local M = {}

M.businessType = "racingTeam"

M.racingTeamBlacklistedModels = {
  atv = true,
  citybus = true,
  lansdale = true,
  md_series = true,
  pigeon = true,
  racetruck = true,
  rockbouncer = true,
  us_semi = true,
  van = true,
  utv = true,
  wl40 = true,
  dumptruck = true,
  midtruck = true,
  PM_Pulling_Tractor = true,
  YB_mini_mod_tractor = true,
}

M.K = {
  MAX_NEW_VEHICLE_OFFERS = 3,
  MAX_RACE_OFFERS_ON_BOARD = 4,
  SCHEDULED_RACE_MIN_SEC = 30,
  SCHEDULED_RACE_MAX_SEC = 90,
  RACING_TEAM_POST_RACE_COOLDOWN_BASE_SEC = 7 * 60,
  -- Gates the player from racing the team's car back-to-back; separate from the per-vehicle and per-driver cooldowns.
  RACING_TEAM_PLAYER_POST_RACE_COOLDOWN_BASE_SEC = 15 * 60,
  -- Team share of the gross payout when the player drove instead of a hired driver; AI and proxy races are unaffected.
  RACING_TEAM_PLAYER_RACE_PAYOUT_MULTIPLIER = 0.25,
  POST_RACE_COOLDOWN_UI_POLL_INTERVAL_SIM = 1,
  RACING_TEAM_COOLDOWN_REDUCTION_PER_LEVEL = 0.05,
  SCHEDULED_RACE_READY_TOAST_INTERVAL = 2.5,
  GOAL_UNLOCK_SANCTIONED_RACE_OFFERS = "rt_t1_g4",
  GOAL_MAKE_YOUR_MARK = "rt_t1_g5",
  GOAL_TIER1_LAST = "rt_t1_g8",
  MAX_LEAGUE2_PULLED_OUT = 5,
  RACING_TEAM_GARAGE_PARKING_CAP = 4,
  RACING_TEAM_SPONSOR_MAX_ACTIVE = 2,
  RACING_TEAM_SPONSOR_MAX_AVAILABLE = 2,
  RACING_TEAM_SPONSOR_BONUS_CAP = 0.35,
  RACING_TEAM_SPONSOR_OFFER_INTERVAL_MIN = 180,
  PROXY_PODIUM_XP_OF_MONEY = 0.1,
  RACING_TEAM_GOALS_PATH = "gameplay/overhaul/business/goals/racingTeamGoals.json",
  sponsorNamePrefixes = {
    "Pacific",
    "Coastal",
    "Summit",
    "Grid",
    "Canyon",
    "Desert",
    "Harbor",
    "Bay",
  },
  sponsorNameSuffixes = {
    "Motors",
    "Performance",
    "Parts",
    "Industries",
    "Racing",
    "Labs",
    "Partners",
  },
}

M.offerStateByBusiness = {}
M.goalCompletionByBusiness = {}
M.tuningMilestoneByBusiness = {}
M.tuningMilestoneByGoalByBusiness = {}
M.homeMechanicBaselinePwByBusiness = {}
M.pendingHomeMechanicPwRecheckByBusiness = {}
M.currentLeagueByBusiness = {}
M.offerJobIdCounters = {}
M.staminaShortTrackStreakByBusiness = {}
M.sanctionedOfficialFirstPlaceWinsByBusiness = {}
M.classOptimizationPeakHpByBusiness = {}
M.persistLoaded = {}

M.vehicleCooldownByBusiness = {}
M.playerCooldownByBusiness = {}
M.allLeaderboardsBaselineByBusiness = {}
M.completedGoalLeaderboardTimesByBusiness = {}

M.businessDrivers = {}
-- Assigned by board.lua when it loads.
M.loadRacingTeamDrivers = nil

M.raceOfferBoardByBusiness = {}
M.pendingRematchOfferByBusiness = {}
M.businessSkillXpByBusiness = {}
-- The save keeps the league2Invite* field names, so the in-memory maps keep them too.
M.league2InviteByBusiness = {}
M.league2InvitePromoUiByBusiness = {}
M.purchaseMilestoneSplashShownByBusiness = {}
M.raceUnlockSplashPendingByBusiness = {}
M.raceUnlockSplashShownByBusiness = {}
M.careerFinaleSplashPendingByBusiness = {}
M.careerFinaleSplashShownByBusiness = {}

M.rtInternal = {
  league2SplashQueued = {},
  purchaseSplashQueued = {},
  goalsPushToken = {},
  sponsors = {},
  racingTeamLevelInfoNormalizedCache = {},
  goalsDefinitionLoaded = false,
  goalsDefinition = nil,
  eligibleVehicleInfoByPair = nil,
}

M.scheduledRaceReadyToastAccumulator = 0
M.postRaceCooldownUiPollAccumulator = 0

M.formatVehicleForUI = nil

M.racingTeamFactoryConfigs = nil

function M.getFactoryConfigs()
  if M.racingTeamFactoryConfigs then
    return M.racingTeamFactoryConfigs
  end
  local eligibleVehicles = util_configListGenerator.getEligibleVehicles(false, false) or {}
  M.racingTeamFactoryConfigs = {}
  for _, vehicleInfo in ipairs(eligibleVehicles) do
    local configType = vehicleInfo["Config Type"]
    if not configType and vehicleInfo.aggregates and vehicleInfo.aggregates["Config Type"] then
      configType = next(vehicleInfo.aggregates["Config Type"])
    end
    if configType == "Factory" and not M.racingTeamBlacklistedModels[vehicleInfo.model_key] then
      table.insert(M.racingTeamFactoryConfigs, vehicleInfo)
    end
  end
  return M.racingTeamFactoryConfigs
end

return M
