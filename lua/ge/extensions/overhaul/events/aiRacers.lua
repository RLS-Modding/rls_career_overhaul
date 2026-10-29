-- Racer staging, power requests and recovery for one extension load.
-- Read configuration and owned state, planning/spawn/drive services, frame updates and public hooks.
local M = {}

-- Host parking work also changes player freeze/staging state; keep the existing update dispatch order.
M.dependencies = {"overhaul_events_competitiveTrackFlow"}

-- Config ------------------------------------------------------------------------------------------

local CONFIG_DIR = "competitiveRace"
local CONFIG_FILENAME = "aiRacers.json"
local CONFIG_RACE_FILENAME = "aiRacingConfig.json"
local DEFAULT_CONFIG = {
  enabled = false,
  maxSpawnCount = 5,
  routeSpeed = 70,
  -- When false, AI speed is controlled by aggression only (like base game missions); when true, routeSpeed caps speed.
  useRouteSpeedLimit = false,
  aggressionMin = 0.6,
  aggressionMax = 0.75,
  avoidCars = "on",
  -- Circuit racing: 'off' lets AI use full track width and racing line; base game missions do not use driveInLane for race AI.
  driveInLane = "off",
  routeSpeedMode = "limit",
  useNavgraphPathfinding = true,
  -- Racing AI tuning (matches base game Race AI Parameters flowgraph). Skill 0-1: higher = tighter line, better avoidance.
  racerSkill = 0.8,
  useRacingParameters = true,
  -- Rubberband: AI eases off when ahead, pushes when behind (optional, like base missions).
  rubberBand = true,
  -- Script path width in metres at each node (prevents narrow path and corner clipping).
  scriptPathWidth = 2.5,
  navTargetReachDistance = 20,
  launchRecoveryGraceSeconds = 6,
  defaultVehiclePool = { "etk800", "sunburst", "200bx", "covet", "vivace", "grandmarshal" },
  recoveryEnabled = true,
  recoverySpeedThresholdMps = 1.0,
  recoveryStuckSeconds = 3.0,
  recoveryCooldownSeconds = 10.0,
  despawnWreckedEnabled = true,
  -- When false, no AI is despawned for stuck/wreck during race; only post-race delayed/clear despawn runs.
  -- Enabled by default so stuck/flipped AI are cleaned up mid-race instead of blocking the racing line on subsequent laps.
  despawnWreckedDuringRace = true,
  despawnUpsideDownSeconds = 8.0,
  despawnAfterRecoveries = 2,
  despawnTerminalStuckSeconds = 15.0,
  despawnAlwaysStuckSeconds = 25.0,
  delayedDespawnDefaultSeconds = 60.0,
  delayedDespawnStaggerSeconds = 4.0,
  startEngineOnSpawn = true,
  scriptBootstrapDistance = 6.0,
  -- AI pool: only spawn rows with hp/kg <= player hp/kg * (1 + aiPowerExceedCapPct). Legacy key filterPoolByPowerMeetOrExceed still accepted.
  filterPoolByPowerWeightMeetOrExceed = true,
  aiPowerExceedCapPct = 0.25,
  -- vehiclePool: AI configs with hp/kg in (player, player + this]; same scale as bracket pw (typ. ~0.04–0.09).
  aiPoolCloseAbovePw = 0.0617,
  -- On-screen ui_message after staging AI spawn (plan + hp/kg). Per-level aiRacers.json; false = off.
  aiSpawnDebugUi = false,
  -- Same payload to beamng.log (I/aiRacers) — works without ui_message; use for sanctioned P/W spawn diagnosis.
  aiSpawnDebugLog = false,
  -- overhaulAi: multiplies lateral/longitudinal grip budget in raceplanAhead (1.0 = default, >1 = faster in corners).
  raceAccelScale = 1.15,
  raceThrottleKp = 1.12,
  -- driveToTarget: throttle pedal ramp (4 matches old state-based when raceAccelScale is set). Higher = on power sooner after braking.
  raceThrottleRateMult = 4,
  raceThrottleRecoveryMult = 1.9,
  -- driveUsingPath setParameters: higher = plan.targetSpeed follows planner faster (exit / straights).
  targetSpeedSmootherRate = 18,
  -- Wide-line racing (overhaulAi): when lateral offset from plan exceeds start→end (m), blend traffic-limited speed back toward geometric cap (never above it).
  -- Bumped after .39 AI caution: recover more speed when already wide instead of settling in pack.
  raceWideLineTrafficBlend = 0.72,
  raceWideLineLateralStartM = 0.75,
  raceWideLineLateralEndM = 2.4,
  -- Soften understeer throttle lift when wide — keeps commitment on an alternate line.
  raceWideLineUndersteerRelax = 0.7,
  -- Corner line sacrifice (overhaulAi): shift plan nodes outward in tight bends (curvature ~1/m). 0 = off.
  raceCornerLineLiftMaxM = 0.28,
  raceCornerCurvStart = 0.022,
  raceCornerCurvEnd = 0.10,
  raceCornerLineLiftScale = 1.0,
  -- overhaulAi aggressive racing (traffic cap + alt plans + side push). Tuned post-.39 for more pass attempts.
  raceTrafficPassBlend = 0.78,
  raceClearanceScaleMin = 0.26,
  -- Wider margins + overhaulAi hysteresis reduce lane flip-flop / indecision vs marginal wins.
  raceAltPlanSpeedMargin = 6.5,
  raceAltPlanTimeMargin = 3.8,
  raceAwarenessCoefScale = 0.95,
  raceBlockedAheadDistMax = 42,
  raceClearancePassMinGainM = 0.4,
  raceClearancePassTrafficEps = 0.3,
  -- overhaulAi: < 1 scales racing brake from speed error (corners / traffic).
  raceBrakeGain = 0.9,
  -- Commit-corner racing
  raceCommitCorners = false,
  -- Safe revert: set raceCornerExitPush=false.
  raceCornerExitPush = true,
  raceCornerExitPushMinGain = 0.8,
  raceCornerExitPushOvershoot = 1.03,
  raceCornerExitPushRiseRate = 18,
  raceCornerExitPushSlipMax = 0.92,
  raceUndersteerSlipMin = 1.05,
  raceCornerGripUtil = 1.32,
  raceCornerPlanBoost = 1.06,
  raceCommitTargetOvershoot = 1.08,
  raceCommitSpeedFloorPct = 0.98,
  raceSlipTarget = 1.14,
  raceGripLiveRiseRate = 28,
  -- When non-empty, vehiclePool configs load from vehicles/<model>/<subdir>/<name>.pc (JSON stays basename-only). Empty = configs in model folder root.
  aiRaceConfigSubdir = "",
}

-- Racing-team proxy bracket spawn: soften AI max hp/kg vs player when read exists (same units as classPw*).
local PROXY_BRACKET_SOFT_PW_BELOW_PLAYER = 0.0265

-- State -------------------------------------------------------------------------------------------

local racerState = {}
racerState.mSpawnedAiVehicleIds = {}
racerState.mSpawnGeneration = 0
-- Keep every spawned id until teardown so transient missing objects cannot leave wrecks behind.
racerState.mEverSpawnedAiVehicleIdsSweep = {} -- [vehId] = true
racerState.mLastSpawnedAiLineupSnapshot = {}
local mPathCache = {} -- racePathKey -> array of { x, y, z }
racerState.mRecoveryStateByVehId = {} -- [vehId] = { stuckTime, cooldown }
racerState.mRetiredUpsideDownByVehId = {} -- [vehId] = true
racerState.mRecoveryMonitorEnabled = false
racerState.mRecoveryCheckAccumulator = 0
racerState.mActiveRaceForRecovery = nil
racerState.mActiveLapCountForRecovery = 1
racerState.mVehicleLaneIndexByVehId = {} -- [vehId] = laneIndex (for recovery to re-use same lane path)
racerState.mNavStateByVehId = {} -- [vehId] = { path, targetIndex, lapsRemaining, aggression, targetX, targetY, targetZ }
racerState.mRecoveryGraceTimer = 0
--- Set false to re-enable mid-race stuck / flip-stop / despawn monitor in `M.onUpdate`.
local DISABLE_AI_RACE_RECOVERY_FOR_TEST = false
racerState.mDelayedDespawnActive = false
racerState.mDelayedDespawnWaiting = false
racerState.mDelayedDespawnTimer = 0
racerState.mDelayedDespawnStaggerSeconds = 4.0
racerState.mPlayerUnfreezeAt = nil -- os.clock() time when to unfreeze player after AI GO (avoids dt spikes)
racerState.mDnfCallback = nil -- called with vehId when an AI is despawned (DNF)
racerState.mGridTeamCarVehId = nil -- Racing Team car set up on the grid and not yet released to its race drive
-- Cache for per-race AI config (aiRacingConfig.json byRace): [levelId] = { byRace = { pathKey -> overrides } }
local mRaceConfigCache = {}
racerState.pendingPowerCallback = nil
racerState.pendingPowerVehId = nil
racerState.pendingPowerRequestGen = 0
racerState.pendingPowerRequestDeadline = nil
local POWER_REQUEST_MAX_RETRIES = 20
local POWER_REQUEST_DEADLINE_SEC = 8

-- Random colors for AI (r g b a, 0-1; a=1). Applied same-frame after spawn so no visible change.
local AI_COLOR_PALETTE = {
  "0.9 0.1 0.1 1", -- red
  "0.1 0.2 0.7 1", -- blue
  "0.95 0.75 0.05 1", -- gold
  "0.1 0.65 0.2 1", -- green
  "0.6 0.1 0.6 1", -- purple
  "0.0 0.0 0.0 1", -- black
  "0.85 0.4 0.0 1", -- orange
  "0.2 0.8 0.9 1", -- cyan
  "0.9 0.9 0.9 1", -- white
  "0.4 0.25 0.1 1", -- brown
  "0.7 0.0 0.0 1", -- dark red
  "0.0 0.35 0.6 1", -- navy
}

-- Parts -------------------------------------------------------------------------------------------

local parts = {}
local ownerServices = {
  M = M,
  CONFIG_DIR = CONFIG_DIR,
  CONFIG_FILENAME = CONFIG_FILENAME,
  CONFIG_RACE_FILENAME = CONFIG_RACE_FILENAME,
  DEFAULT_CONFIG = DEFAULT_CONFIG,
  PROXY_BRACKET_SOFT_PW_BELOW_PLAYER = PROXY_BRACKET_SOFT_PW_BELOW_PLAYER,
  racerState = racerState,
  mPathCache = mPathCache,
  mRaceConfigCache = mRaceConfigCache,
  AI_COLOR_PALETTE = AI_COLOR_PALETTE,
  parts = parts,
}
parts.config = require("overhaul/events/aiRacers/aiRacersConfig").create(ownerServices)
parts.planner = require("overhaul/events/aiRacers/aiRacersPlanner").create(ownerServices)
parts.spawn = require("overhaul/events/aiRacers/aiRacersSpawn").create(ownerServices)
parts.drive = require("overhaul/events/aiRacers/aiRacersDrive").create(ownerServices)

-- Per-frame update --------------------------------------------------------------------------------

local function expirePendingRacerPowerRequest()
  if
    type(racerState.pendingPowerCallback) == "function"
    and racerState.pendingPowerVehId
    and racerState.pendingPowerRequestGen > 0
  then
    local now = os.clock()
    local activeGen = racerState.pendingPowerRequestGen
    if racerState.pendingPowerRequestDeadline and now > racerState.pendingPowerRequestDeadline then
      if activeGen == racerState.pendingPowerRequestGen then M.onPlayerVehiclePowerWeight(0, nil) end
    end
  end
end

local function releaseTimedPlayerFreeze()
  if racerState.mPlayerUnfreezeAt and os.clock() >= racerState.mPlayerUnfreezeAt then
    racerState.mPlayerUnfreezeAt = nil
    M.setPlayerFreeze(false)
  end
end

local function racerRecoveryLimits(cfg)
  local recoveryEnabled = cfg.recoveryEnabled ~= false
  local speedThreshold =
    math.max(0, tonumber(cfg.recoverySpeedThresholdMps) or DEFAULT_CONFIG.recoverySpeedThresholdMps)
  local stuckSeconds = math.max(0.5, tonumber(cfg.recoveryStuckSeconds) or DEFAULT_CONFIG.recoveryStuckSeconds)
  local cooldownSeconds = math.max(1, tonumber(cfg.recoveryCooldownSeconds) or DEFAULT_CONFIG.recoveryCooldownSeconds)
  local despawnEnabled = cfg.despawnWreckedEnabled ~= false
  local upsideDownDespawnSeconds =
    math.max(2, tonumber(cfg.despawnUpsideDownSeconds) or DEFAULT_CONFIG.despawnUpsideDownSeconds)
  local despawnAfterRecoveries =
    math.max(1, tonumber(cfg.despawnAfterRecoveries) or DEFAULT_CONFIG.despawnAfterRecoveries)
  local terminalStuckSeconds =
    math.max(stuckSeconds, tonumber(cfg.despawnTerminalStuckSeconds) or DEFAULT_CONFIG.despawnTerminalStuckSeconds)
  local alwaysStuckSeconds =
    math.max(terminalStuckSeconds, tonumber(cfg.despawnAlwaysStuckSeconds) or DEFAULT_CONFIG.despawnAlwaysStuckSeconds)
  return {
    recoveryEnabled = recoveryEnabled,
    speedThreshold = speedThreshold,
    stuckSeconds = stuckSeconds,
    cooldownSeconds = cooldownSeconds,
    despawnEnabled = despawnEnabled,
    upsideDownDespawnSeconds = upsideDownDespawnSeconds,
    despawnAfterRecoveries = despawnAfterRecoveries,
    terminalStuckSeconds = terminalStuckSeconds,
    alwaysStuckSeconds = alwaysStuckSeconds,
  }
end

local function retireUpsideDownRacer(vehId, vehObj, state, step, limits, toDespawn)
  state.upsideDownTime = (state.upsideDownTime or 0) + step
  racerState.mRetiredUpsideDownByVehId[vehId] = true
  vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
  vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
  if limits.despawnEnabled and state.upsideDownTime >= limits.upsideDownDespawnSeconds then toDespawn[vehId] = true end
  state.stuckTime = 0
  state.terminalStuckTime = 0
  state.alwaysStuckTime = 0
  racerState.mRecoveryStateByVehId[vehId] = state
end

local function recoverUprightRacer(vehId, vehObj, state, step, limits, toDespawn)
  state.upsideDownTime = 0
  if not racerState.mRetiredUpsideDownByVehId[vehId] then
    state.cooldown = math.max(0, (state.cooldown or 0) - step)

    local speed = parts.drive.getObjectSpeedMps(vehId)
    if speed <= limits.speedThreshold then
      state.stuckTime = (state.stuckTime or 0) + step
      state.terminalStuckTime = (state.terminalStuckTime or 0) + step
      state.alwaysStuckTime = (state.alwaysStuckTime or 0) + step
    else
      state.stuckTime = 0
      state.terminalStuckTime = 0
      state.alwaysStuckTime = 0
    end

    if limits.recoveryEnabled and state.stuckTime >= limits.stuckSeconds and state.cooldown <= 0 then
      vehObj:queueLuaCommand([[
                            if recovery then
                                recovery.startRecovering()
                                recovery.stopRecovering()
                            end
                        ]])
      -- Re-drive with the race's own route settings, the ones the start used; the level default
      -- would switch a script-path race such as Short Track to navgraph routing.
      parts.drive.queueDriveForVehicle(
        vehObj,
        racerState.mActiveRaceForRecovery,
        racerState.mActiveLapCountForRecovery,
        parts.config.getMergedConfigForRace(racerState.mActiveRaceForRecovery),
        racerState.mVehicleLaneIndexByVehId[vehId]
      )
      state.recoveries = (state.recoveries or 0) + 1
      state.stuckTime = 0
      state.cooldown = limits.cooldownSeconds
    end

    if
      limits.despawnEnabled
      and (state.recoveries or 0) >= limits.despawnAfterRecoveries
      and (state.terminalStuckTime or 0) >= limits.terminalStuckSeconds
    then
      toDespawn[vehId] = true
    end
    if limits.despawnEnabled and (state.alwaysStuckTime or 0) >= limits.alwaysStuckSeconds then toDespawn[vehId] = true end
  end
  racerState.mRecoveryStateByVehId[vehId] = state
end

local function updateRacerRecoveryVehicle(vehId, step, limits, toDespawn)
  local vehObj = be:getObjectByID(vehId)
    if not vehObj then return end
  local state = racerState.mRecoveryStateByVehId[vehId]
    or {
      stuckTime = 0,
      cooldown = 0,
      recoveries = 0,
      upsideDownTime = 0,
      terminalStuckTime = 0,
      alwaysStuckTime = 0,
    }
    local upsideDown = parts.drive.isUpsideDown(vehObj)
    if upsideDown then
      retireUpsideDownRacer(vehId, vehObj, state, step, limits, toDespawn)
    else
      recoverUprightRacer(vehId, vehObj, state, step, limits, toDespawn)
    end
end

function M.onUpdate(dtReal)
  local dt = tonumber(dtReal) or 0
  if dt <= 0 then return end
  expirePendingRacerPowerRequest()
  releaseTimedPlayerFreeze()
  if parts.drive.updateDelayedDespawn(dt) then return end

  if not racerState.mRecoveryMonitorEnabled then return end
  if not racerState.mSpawnedAiVehicleIds or #racerState.mSpawnedAiVehicleIds == 0 then return end
  if not racerState.mActiveRaceForRecovery then return end
  if DISABLE_AI_RACE_RECOVERY_FOR_TEST then return end

  local cfg = parts.config.getCurrentLevelConfig()
  if cfg.enabled == false then return end
  -- When false, do not despawn any AI for stuck/wreck during race; only post-race cleanup runs.
  if cfg.despawnWreckedDuringRace == false then return end
  if racerState.mRecoveryGraceTimer and racerState.mRecoveryGraceTimer > 0 then
    racerState.mRecoveryGraceTimer = math.max(0, racerState.mRecoveryGraceTimer - dt)
    return
  end

  racerState.mRecoveryCheckAccumulator = racerState.mRecoveryCheckAccumulator + dt
  if racerState.mRecoveryCheckAccumulator < 0.2 then return end
  local step = racerState.mRecoveryCheckAccumulator
  racerState.mRecoveryCheckAccumulator = 0

  local limits = racerRecoveryLimits(cfg)
  local toDespawn = {}
  for _, vehId in ipairs(racerState.mSpawnedAiVehicleIds) do
    updateRacerRecoveryVehicle(vehId, step, limits, toDespawn)
  end
  parts.drive.despawnAiVehiclesById(toDespawn)
end

-- Public API --------------------------------------------------------------------------------------

M.spawnForStagingWithPlayerPw = M.spawnForStagingWithPlayerHp

function M.scheduleDelayedDespawn(delaySeconds, staggerSeconds)
  if not racerState.mSpawnedAiVehicleIds or #racerState.mSpawnedAiVehicleIds == 0 then
    parts.drive.resetDelayedDespawnState()
    return 0
  end
  local cfg = parts.config.getCurrentLevelConfig()
  local delay = tonumber(delaySeconds)
  if not delay then
    delay = tonumber(cfg.delayedDespawnDefaultSeconds) or DEFAULT_CONFIG.delayedDespawnDefaultSeconds
  end
  local stagger = tonumber(staggerSeconds)
  if not stagger then
    stagger = tonumber(cfg.delayedDespawnStaggerSeconds) or DEFAULT_CONFIG.delayedDespawnStaggerSeconds
  end
  racerState.mDelayedDespawnActive = true
  racerState.mDelayedDespawnWaiting = true
  racerState.mDelayedDespawnTimer = math.max(0, delay)
  racerState.mDelayedDespawnStaggerSeconds = math.max(0.25, stagger)
  racerState.mRecoveryMonitorEnabled = false
  racerState.mRecoveryCheckAccumulator = 0
  return #racerState.mSpawnedAiVehicleIds
end

-- One-shot ignition pass for all currently spawned AI (used during staging pre-countdown).
function M.startEnginesForSpawned()
  local cfg = parts.config.getCurrentLevelConfig()
  if cfg.enabled == false then return 0 end
  local started = 0
  for _, vehId in ipairs(racerState.mSpawnedAiVehicleIds) do
    local obj = be:getObjectByID(vehId)
    if obj then
      racerState.queueEngineStart(obj)
      started = started + 1
    end
  end
  return started
end

-- Return list of spawned AI vehicle IDs (for start trigger to count AI laps).
function M.getSpawnedVehicleIds()
  return racerState.mSpawnedAiVehicleIds
end

function M.getLastSpawnedLineupSnapshot()
  return parts.config.copyLineupSnapshot(racerState.mLastSpawnedAiLineupSnapshot)
end

function M.spawnForStagingWithExactLineup(raceName, race, facilityName, lineup)
  if type(lineup) ~= "table" or #lineup == 0 then return 0 end
  local sanitized = {}
  for _, row in ipairs(lineup) do
    if
      type(row) == "table"
      and type(row.model) == "string"
      and row.model ~= ""
      and type(row.config) == "string"
      and row.config ~= ""
    then
      table.insert(sanitized, {
        model = row.model,
        config = row.config,
        matchPw = tonumber(row.matchPw) or tonumber(row.powerHp) or nil,
      })
    end
  end
  if #sanitized == 0 then return 0 end
  return parts.spawn.spawnWithModelConfigList(raceName, race, facilityName, sanitized)
end

function M.setDnfCallback(cb)
  racerState.mDnfCallback = cb
end

-- Teardown sweeps active and orphan ids because physics can briefly hide a surviving vehicle.
function M.getSpawnGeneration()
  return racerState.mSpawnGeneration
end

function M.clearSpawned()
  racerState.mSpawnGeneration = racerState.mSpawnGeneration + 1
  local activeSet = {}
  for _, vehId in ipairs(racerState.mSpawnedAiVehicleIds) do
    activeSet[vehId] = true
  end
  local union = {}
  for vehId in pairs(activeSet) do
    union[vehId] = true
  end
  for vehId in pairs(racerState.mEverSpawnedAiVehicleIdsSweep) do
    union[vehId] = true
  end
  local orphansDeleted = 0
  for vehId in pairs(union) do
    if racerState.mDnfCallback then pcall(racerState.mDnfCallback, vehId) end
    local obj = be:getObjectByID(vehId)
    if obj then
      obj:delete()
      if not activeSet[vehId] then orphansDeleted = orphansDeleted + 1 end
    end
  end
  if orphansDeleted > 0 then
    log(
      "W",
      "aiRacers",
      string.format(
        "clearSpawned: swept %d orphan AI vehicle(s) that had been dropped from the active list without deletion",
        orphansDeleted
      )
    )
  end
  racerState.mSpawnedAiVehicleIds = {}
  racerState.mEverSpawnedAiVehicleIdsSweep = {}
  racerState.mRecoveryStateByVehId = {}
  racerState.mRetiredUpsideDownByVehId = {}
  racerState.mVehicleLaneIndexByVehId = {}
  racerState.mNavStateByVehId = {}
  racerState.mRecoveryMonitorEnabled = false
  racerState.mRecoveryCheckAccumulator = 0
  racerState.mActiveRaceForRecovery = nil
  racerState.mActiveLapCountForRecovery = 1
  racerState.mRecoveryGraceTimer = 0
  parts.drive.resetDelayedDespawnState()
end

function M.invalidateConfigCache()
  -- no-op: config is read from disk each time getCurrentLevelConfig() is called
end

-- HP reading and class eligibility for player (race staging).
-- Class order and max HP per class (player eligible if vehicle power <= eligibilityPct * classMax).
local CLASS_ORDER = { "D", "C", "B", "A" }
local CLASS_MAX_HP = { D = 160, C = 370, B = 600, A = 9999 }
local ELIGIBILITY_PCT = 0.75
-- XP thresholds: at least this much business XP to be in that class (D=0, C=1500, B=5000, A=15000).
local XP_FOR_CLASS = { D = 0, C = 1500, B = 5000, A = 15000 }

-- Fresh live sample (from vehicle VM): HP + weight → hp/kg for staging UI and podium cap.
racerState.mCachedLivePlayerHp = nil
racerState.mCachedLivePlayerWeightKg = nil
racerState.mCachedLivePlayerPw = nil
racerState.mCachedLivePlayerVehId = nil
racerState.mCachedLivePlayerClock = nil
local LIVE_HP_CACHE_STALE_SEC = 90

-- Player vehicle power and eligibility ------------------------------------------------------------

local function invalidateLiveHpCacheIfVehicleChanged()
  local pid = be:getPlayerVehicleID(0)
  if not pid or not racerState.mCachedLivePlayerVehId or pid ~= racerState.mCachedLivePlayerVehId then
    racerState.mCachedLivePlayerHp = nil
    racerState.mCachedLivePlayerWeightKg = nil
    racerState.mCachedLivePlayerPw = nil
    racerState.mCachedLivePlayerVehId = nil
    racerState.mCachedLivePlayerClock = nil
  end
end

local function liveHpSampleIsTrusted()
  invalidateLiveHpCacheIfVehicleChanged()
  if type(racerState.mCachedLivePlayerHp) ~= "number" or racerState.mCachedLivePlayerHp <= 0 then return false end
  if not racerState.mCachedLivePlayerClock then return false end
  local clk = (os and os.clock) and os.clock() or 0
  return (clk - racerState.mCachedLivePlayerClock) < LIVE_HP_CACHE_STALE_SEC
end

local function storeLivePowerSampleForVehicle(vehId, powerWatts, weightKg)
  if not vehId or vehId ~= be:getPlayerVehicleID(0) then return end
  if type(powerWatts) ~= "number" or powerWatts <= 0 then return end
  local hp = parts.planner.powerWattsToHp(powerWatts)
  if type(hp) ~= "number" or hp <= 0 then return end
  racerState.mCachedLivePlayerHp = hp
  racerState.mCachedLivePlayerWeightKg = tonumber(weightKg)
  if racerState.mCachedLivePlayerWeightKg and racerState.mCachedLivePlayerWeightKg > 0 then
    racerState.mCachedLivePlayerPw = parts.planner.hpPerKgFromHpAndWeightKg(hp, racerState.mCachedLivePlayerWeightKg)
  else
    racerState.mCachedLivePlayerPw = nil
  end
  racerState.mCachedLivePlayerVehId = vehId
  racerState.mCachedLivePlayerClock = os.clock()
end
-- Vehicle script: max maxPower over all "engine" devices (raw may be HP-scale or watts; GE normalizes in onPlayerVehiclePowerWeight), beam stats weight, both required before success.
-- Retries until power>0 and weight>0 or max retries (then report last values).
M._powerRequestScriptTemplate = [[
local retry = %d
local maxR = %d
local reqGen, requestId = %d, %d
local power, weight = 0, 0
local engines = powertrain.getDevicesByCategory("engine")
if engines then
  for _, eng in ipairs(engines) do
    if eng and eng.maxPower then
      local mp = eng.maxPower or 0
      if mp > power then power = mp end
    end
  end
end
local stats = obj:calcBeamStats()
if stats and stats.total_weight then weight = stats.total_weight end
local ready = power > 0 and weight > 0
if ready or retry >= maxR then
  obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(requestId, "onPlayerVehiclePowerWeight", tostring(power) .. "," .. tostring(weight) .. "," .. tostring(reqGen)))
else
  obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(requestId, "onPlayerVehiclePowerWeightRetry", tostring(retry) .. "," .. tostring(reqGen)))
end
]]
function M._openPowerRequest(vehId)
  return require("overhaul/lib/vehicles/callbacks").open(
    "onPlayerVehiclePowerWeight",
    { owner = "aiRacers", vehId = vehId, answers = { onPlayerVehiclePowerWeightRetry = true }, supersede = true }
  )
end
-- One-shot VM read for staging UI refresh; does not use pendingPowerCallback (safe alongside AI spawn).
M._livePowerCacheScript = [[
local power, weight = 0, 0
local engines = powertrain.getDevicesByCategory("engine")
if engines then
  for _, eng in ipairs(engines) do
    if eng and eng.maxPower then
      local mp = eng.maxPower or 0
      if mp > power then power = mp end
    end
  end
end
local stats = obj:calcBeamStats()
if stats and stats.total_weight then weight = stats.total_weight end
if power > 0 and weight > 0 then
  local vid = obj:getID()
  obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').command("ingestLivePowerCacheSample", tostring(vid) .. "," .. tostring(power) .. "," .. tostring(weight)))
end
]]

local function getEffectiveClassFromXp(cfg, businessXp)
  local xp = tonumber(businessXp) or 0
  local class = "D"
  for i = #CLASS_ORDER, 1, -1 do
    local c = CLASS_ORDER[i]
    local threshold = (cfg and cfg.horsepowerClassXp and cfg.horsepowerClassXp[c]) or XP_FOR_CLASS[c]
    if xp >= (tonumber(threshold) or 0) then
      class = c
      break
    end
  end
  return class
end

local function getEligibilityThresholdForClass(cfg, class)
  local maxHp = (cfg and cfg.horsepowerClassRanges and cfg.horsepowerClassRanges[class]) or CLASS_MAX_HP[class]
  local pct = (cfg and cfg.eligibilityPct) or ELIGIBILITY_PCT
  if not maxHp then return nil end
  return math.floor((tonumber(maxHp) or 0) * (tonumber(pct) or ELIGIBILITY_PCT))
end

-- Returns player vehicle model key and config key (e.g. "etkc", "default") or nil, nil if not available.
function M.getPlayerVehicleModelAndConfig()
  local vehId = be:getPlayerVehicleID(0)
  if not vehId then return nil, nil end
  local details = core_vehicles.getVehicleDetails(vehId)
  if not details or not details.current then return nil, nil end
  local modelKey = details.current.key
  local configKey = details.current.config_key or "default"
  return modelKey, configKey
end

-- GE entry from vehicle VM: updates live HP cache only (no pendingPowerCallback).
function M.ingestLivePowerCacheSample(vid, powerRaw, weightRaw)
  vid = tonumber(vid)
  if not vid or vid ~= be:getPlayerVehicleID(0) then return end
  local pRaw = tonumber(powerRaw)
  local wRaw = tonumber(weightRaw)
  if not pRaw or not wRaw or wRaw <= 0 then return end
  local p = parts.planner.liveMaxPowerRawToWatts(pRaw)
  if not p or p <= 0 then return end
  storeLivePowerSampleForVehicle(vid, p, wRaw)
end

-- Staging UI: prefer fresh live sample; fall back to sync getVehicleDetails (display only).
function M.getPlayerVehiclePowerForStagingUi()
  if liveHpSampleIsTrusted() then return racerState.mCachedLivePlayerHp, "live" end
  return M.getPlayerVehiclePower(), "sync"
end

function M.getPlayerVehiclePwForStagingUi()
  if
    liveHpSampleIsTrusted()
    and type(racerState.mCachedLivePlayerPw) == "number"
    and racerState.mCachedLivePlayerPw > 0
  then
    return racerState.mCachedLivePlayerPw, "live"
  end
  return select(1, M.getPlayerVehiclePowerAndClass()), "sync"
end

-- Podium class cap (legacy HP): trusted live HP only.
function M.getPlayerVehiclePowerForPodiumCapCheck()
  if liveHpSampleIsTrusted() then return racerState.mCachedLivePlayerHp end
  return nil
end

--- Sanctioned podium: trusted live hp/kg only (requires power + weight in cache).
function M.getPlayerVehiclePwForPodiumCapCheck()
  if
    liveHpSampleIsTrusted()
    and type(racerState.mCachedLivePlayerPw) == "number"
    and racerState.mCachedLivePlayerPw > 0
  then
    return racerState.mCachedLivePlayerPw
  end
  return nil
end

-- Throttled from competitiveTrackFlow while staging UI is open; skipped if a reliable power request is in flight.
function M.requestStagingUiLivePowerRefresh()
  if racerState.pendingPowerCallback ~= nil then return end
  local vehId = be:getPlayerVehicleID(0)
  if not vehId then return end
  local vehObj = be:getObjectByID(vehId)
  if not vehObj or not vehObj.queueLuaCommand then return end
  vehObj:queueLuaCommand(M._livePowerCacheScript)
end

-- Sync: may return nil if power cannot be read (e.g. no vehicle). Returns power in HP (same as filter/comparison).
function M.getPlayerVehiclePower()
  local vehId = be:getPlayerVehicleID(0)
  if not vehId then return nil end
  local details = core_vehicles.getVehicleDetails(vehId)
  if not details then return nil end
  local configs = details.configs
  if not configs then return nil end
  return parts.planner.getPowerHpFromConfig(configs)
end

-- Sync curb weight (kg) from vehicle details config, or nil.
function M.getPlayerVehicleWeightKg()
  local vehId = be:getPlayerVehicleID(0)
  if not vehId then return nil end
  local details = core_vehicles.getVehicleDetails(vehId)
  if not details or not details.configs then return nil end
  return parts.planner.getWeightKgFromConfig(details.configs)
end

-- Returns player hp/kg and vehiclePool tier class when sync power+weight available.
function M.getPlayerVehiclePowerAndClass()
  local vehId = be:getPlayerVehicleID(0)
  if not vehId then return nil, nil end
  local details = core_vehicles.getVehicleDetails(vehId)
  if not details or not details.configs then return nil, nil end
  local hp = parts.planner.getPowerHpFromConfig(details.configs)
  local wkg = parts.planner.getWeightKgFromConfig(details.configs)
  local pw = parts.planner.hpPerKgFromHpAndWeightKg(hp, wkg)
  if not pw then return nil, nil end
  return pw, parts.planner.getClassFromPwForVehiclePool(pw)
end

-- Called from vehicle Lua (queueGameEngineLua) with live power/weight.
-- Power may be HP-scale or watts; normalize to watts before callback (see liveMaxPowerRawToWatts).
function M.onPlayerVehiclePowerWeight(power, weight, gen)
  if gen ~= nil and gen ~= racerState.pendingPowerRequestGen then return end
  racerState.pendingPowerRequestDeadline = nil
  local cb = racerState.pendingPowerCallback
  local vidForCache = racerState.pendingPowerVehId
  racerState.pendingPowerCallback = nil
  racerState.pendingPowerVehId = nil
  if type(cb) == "function" then
    local p = (type(power) == "number") and parts.planner.liveMaxPowerRawToWatts(power) or nil
    local w = (type(weight) == "number") and weight or nil
    if vidForCache and p and p > 0 and w and w > 0 then storeLivePowerSampleForVehicle(vidForCache, p, w) end
    cb(p, w)
  end
end

-- Vehicle calls this when engine not ready yet; we re-queue the script with retry+1 (Option B).
function M.onPlayerVehiclePowerWeightRetry(retryCount, gen)
  if gen ~= nil and gen ~= racerState.pendingPowerRequestGen then return end
  if type(racerState.pendingPowerCallback) ~= "function" or not racerState.pendingPowerVehId then return end
  if type(retryCount) ~= "number" or retryCount >= POWER_REQUEST_MAX_RETRIES then
    M.onPlayerVehiclePowerWeight(0, nil, racerState.pendingPowerRequestGen)
    return
  end
  local vehObj = be:getObjectByID(racerState.pendingPowerVehId)
  if vehObj and vehObj.queueLuaCommand then
    vehObj:queueLuaCommand(
      string.format(
        M._powerRequestScriptTemplate,
        retryCount + 1,
        POWER_REQUEST_MAX_RETRIES,
        racerState.pendingPowerRequestGen,
        M._openPowerRequest(racerState.pendingPowerVehId)
      )
    )
  else
    M.onPlayerVehiclePowerWeight(0, nil, racerState.pendingPowerRequestGen)
  end
end

local function beginPendingPowerRequest(callback, vehId)
  if type(racerState.pendingPowerCallback) == "function" then
    local oldCb = racerState.pendingPowerCallback
    racerState.pendingPowerCallback = nil
    racerState.pendingPowerVehId = nil
    racerState.pendingPowerRequestDeadline = nil
    oldCb(nil, nil)
  end
  racerState.pendingPowerRequestGen = racerState.pendingPowerRequestGen + 1
  racerState.pendingPowerCallback = callback
  racerState.pendingPowerVehId = vehId
  racerState.pendingPowerRequestDeadline = os.clock() + POWER_REQUEST_DEADLINE_SEC
  return racerState.pendingPowerRequestGen
end

-- Request live power/weight. opts.preferLive: skip sync getVehicleDetails; use vehicle queueLuaCommand only (tuning-shop style, no UI activeObjectLua).
-- Default: sync details first, then request the player's vehicle directly.
function M.getPlayerVehiclePowerReliable(callback, opts)
  if type(callback) ~= "function" then return end
  local vehId = be:getPlayerVehicleID(0)
  if not vehId then
    callback(nil, nil)
    return
  end

  local preferLive = type(opts) == "table" and opts.preferLive == true

  -- Option A: sync from vehicle details (fast but can be stale after parts/tuning until details refresh).
  if not preferLive then
    local powerHp = M.getPlayerVehiclePower()
    if type(powerHp) == "number" and powerHp > 0 then
      local details = core_vehicles.getVehicleDetails(vehId)
      local weight = (details and details.configs and details.configs.total_weight)
        or (details and details.aggregates and details.aggregates.total_weight)
        or nil
      callback(powerHp * parts.planner.WATTS_PER_HP, weight)
      return
    end
  end

  local vehObj = be:getObjectByID(vehId)
  if not vehObj or not vehObj.queueLuaCommand then
    callback(nil, nil)
    return
  end
  local reqGen = beginPendingPowerRequest(callback, vehId)
  -- Option B: vehicle script retries until engine has maxPower or max retries (same vehicle via pendingPowerVehId).
  vehObj:queueLuaCommand(
    string.format(M._powerRequestScriptTemplate, 0, POWER_REQUEST_MAX_RETRIES, reqGen, M._openPowerRequest(vehId))
  )
end

-- Sync eligibility: returns ok, msg. Fails open if power cannot be read.
function M.isPlayerEligibleForRace(race, businessXp)
  if not race then return true, nil end
  local cfg = parts.config.getCurrentLevelConfig()
  local effectiveClass = getEffectiveClassFromXp(cfg, businessXp)
  local threshold = getEligibilityThresholdForClass(cfg, effectiveClass)
  if not threshold then return true, nil end
  local power = M.getPlayerVehiclePower()
  if power == nil then return true, nil end
  if power > threshold then
    return false, string.format("Vehicle exceeds Class %s limit (%d HP max for this race).", effectiveClass, threshold)
  end
  return true, nil
end

-- Async eligibility: requests reliable power from vehicle, then checks. Fails closed if power cannot be read.
function M.isPlayerEligibleForRaceAsync(race, businessXp, callback)
  if type(callback) ~= "function" then return end
  if not race then
    callback(true, nil)
    return
  end
  local cfg = parts.config.getCurrentLevelConfig()
  local effectiveClass = getEffectiveClassFromXp(cfg, businessXp)
  local threshold = getEligibilityThresholdForClass(cfg, effectiveClass)
  if not threshold then
    callback(true, nil)
    return
  end
  M.getPlayerVehiclePowerReliable(function(powerWatts, weight)
    if powerWatts == nil then
      callback(false, "Vehicle power could not be read. Try again or use a different vehicle.")
      return
    end
    local powerHp = parts.planner.powerWattsToHp(powerWatts)
    if not powerHp or powerHp > threshold then
      callback(
        false,
        string.format("Vehicle exceeds Class %s limit (%d HP max for this race).", effectiveClass, threshold)
      )
      return
    end
    callback(true, nil)
  end)
end

M.getMergedConfigForRace = parts.config.getMergedConfigForRace

return M
