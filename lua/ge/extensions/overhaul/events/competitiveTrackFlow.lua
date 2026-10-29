-- Circuit staging, grid countdown and racing-team proxy parking/navigation.
-- Read configuration and state, grid/proxy services, staging operations, frame updates and lifecycle hooks.
local M = {}

M.dependencies = { "overhaul_events_session" }

local circuitConfig = require("overhaul/lib/events/circuitConfig")
local statePush = require("overhaul/lib/ui/statePush")

-- Config ------------------------------------------------------------------------------------------

local TRACK_GRID_STAGE_STOP_MPH = 2.5
local TRACK_GRID_PARKING_COMMIT_PADDING_M = 0.25
local TRACK_GRID_AI_SPAWN_WAIT_SEC = 12
--- After showing proxy team loading overlay, yield this long so it can paint before teleport/enter.
local RACING_TEAM_PROXY_TEAM_LOADING_PAINT_DELAY_SEC = 0.45
--- Total AI-spawn attempts under the proxy loading overlay before bailing (1 initial + retries).
local MAX_PROXY_STAGING_AI_ATTEMPTS = 2

local SANCTIONED_PARKING_UI_PUSH_INTERVAL = 0.2
local SANCTIONED_PARKING_LIVE_HP_REFRESH_INTERVAL = 2
local SANCTIONED_CLASS_BRANCHES = { "stock", "modified", "super", "open" }

-- State ---------------------------------------------------------------------------------------------

M.trackFlowState = {
  useAltRoute = false,
  inTrackFlowContext = false,
  sanctionedCareerGoToRaceActive = false,
  sanctionedPoolRefPw = nil,
  sanctionedRaceLapCount = nil,
  -- Racing team proxy: staging at track (not phone sanctioned).
  racingTeamProxyRaceActive = false,
  racingTeamProxyBusinessId = nil,
  racingTeamProxyFleetVehicleId = nil,
  racingTeamProxyRaceSession = false,
  racingTeamProxySessionBusinessId = nil,
  racingTeamProxySessionFleetVehicleId = nil,
  --- Racing-team proxy: sanctioned classPwMax/classPwMin (hp/kg) from offer snapshot; legacy keys *AiPoolRefHp.
  racingTeamProxyAiPoolRefHp = nil,
  racingTeamProxyAiPoolMinHp = nil,
  --- When true, AI spawn picks random configs in [classPwMin, classPwMax] only (ignores live player hp/kg).
  racingTeamProxyAiPoolBracketOnly = false,
  --- 0..1 from proxy driver skill tier; passed to AI spawn only (offer/UI unchanged).
  racingTeamProxyAiDifficultyT = nil,
  --- When not false, show mod Vue fullscreen (`racingTeamProxyTeamLoading`) during racing-team proxy staging; not phone/sanctioned.
  racingTeamProxyStagingLoadingOverlay = true,
}

local trackFlowState = {}
trackFlowState.mCompetitiveAwaitingAiSpawn = false
trackFlowState.mTrackGridParkingAiSpawnStarted = false
trackFlowState.mTrackGridAiSpawnWaitDeadline = nil
trackFlowState.mCompetitiveCountdownJobActive = false
trackFlowState.mCompetitiveCountdownCancel = false
trackFlowState.mCompetitiveCountdownGeneration = 0
trackFlowState.mPlayerStagingSpot = nil
trackFlowState.mPlayerStagingSpotLoadLevel = nil
trackFlowState.mPlayerStagingSpotLoadAttempted = false

trackFlowState.mSanctionedParkingUiPhase = "hidden"
trackFlowState.mSanctionedParkingUiPushClock = nil
trackFlowState.mSanctionedParkingLiveRefreshClock = nil

-- Class labels --------------------------------------------------------------------------------------

local function sanitizeBracketLabel(label)
  local s = tostring(label or ""):lower()
  s = s:gsub("%s*%b()%s*$", "")
  return s:gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalizeClassTier(label)
  local s = tostring(label or ""):lower()
  if s:find("entry", 1, true) or s:find("low", 1, true) or s:find("lower", 1, true) then return "entry" end
  if s:find("upper", 1, true) or s:find("high", 1, true) then return "upper" end
  if s:find("mid", 1, true) or s:find("medium", 1, true) then return "mid" end
  return ""
end

local function resolveClassBranch(label, branch)
  local src = tostring(label or ""):lower()
  for _, b in ipairs(SANCTIONED_CLASS_BRANCHES) do
    if src:find(b, 1, true) then return b end
  end
  local fromBranch = tostring(branch or ""):lower()
  for _, b in ipairs(SANCTIONED_CLASS_BRANCHES) do
    if fromBranch:find(b, 1, true) then return b end
  end
  return ""
end

local function pwBucketX1000(pw)
  local n = tonumber(pw)
  if not n or n <= 0 then return nil end
  return math.floor((n * 1000) / 50) * 50
end

local function formatSanctionedClassWithBucket(label, branch, pwSource)
  local clean = sanitizeBracketLabel(label)
  local b = resolveClassBranch(clean, branch)
  local tier = normalizeClassTier(clean)
  local compact = ""
  if b ~= "" and tier ~= "" then
    compact = b .. "-" .. tier
  elseif b ~= "" then
    compact = b
  end
  if compact == "open" then return "open (500+)", 500 end
  local bucket = pwBucketX1000(pwSource)
  if compact ~= "" and bucket then return string.format("%s (%d)", compact, bucket), bucket end
  if compact ~= "" then return compact, bucket end
  if bucket then return string.format("pw (%d)", bucket), bucket end
  return "", nil
end

trackFlowState.mCachedPlayerStagingSpotName = nil
trackFlowState.mCachedPlayerStagingSpotNameLevel = nil
local mPlayerStagingCornerMarkers = {}
trackFlowState.mRacingTeamProxyNextAttemptClock = nil
--- True while async proxy staging job runs (teleport+AI tail or begin-tail; prevents parking loop from double-scheduling).
trackFlowState.mRacingTeamProxyStagingTeleportJobActive = false

--- True while UI is reduced to RacingTeamProxyOverlay + freeroamRaceHud (body overlays); dock/canvas apps hidden.
--- Includes `spectateStaging` (Spectate clicked) before teleport / in-race.
trackFlowState.mRacingTeamProxySpectatorUiMinimalActive = false

local trackFlowProxy = require("overhaul/events/competitiveTrackFlow/trackFlowProxy").create({
  M = M,
  TRACK_GRID_AI_SPAWN_WAIT_SEC = TRACK_GRID_AI_SPAWN_WAIT_SEC,
  MAX_PROXY_STAGING_AI_ATTEMPTS = MAX_PROXY_STAGING_AI_ATTEMPTS,
  tf = trackFlowState,
})
local refreshProxySpectatorUiIfMinimal = trackFlowProxy.refreshProxySpectatorUiIfMinimal
local restoreRacingTeamProxySpectatorUiAfterMinimal = trackFlowProxy.restoreRacingTeamProxySpectatorUiAfterMinimal
local racingTeamProxyUseTeamLoadingOverlay = trackFlowProxy.racingTeamProxyUseTeamLoadingOverlay
local racingTeamProxyResetAiSpawnBookkeeping = trackFlowProxy.racingTeamProxyResetAiSpawnBookkeeping
local racingTeamProxyRunStagingTailAfterPlayerInTeamCar =
  trackFlowProxy.racingTeamProxyRunStagingTailAfterPlayerInTeamCar
local racingTeamRaceFlowMod = trackFlowProxy.racingTeamRaceFlowMod
local syncRacingTeamProxyBracketFromRequest = trackFlowProxy.syncRacingTeamProxyBracketFromRequest

-- Staging spots and markers -------------------------------------------------------------------------

local function getPlayerStagingSpotNameForLevel()
  local definition = M.getCompetitiveRaceDefinition(M.getCompetitiveRaceId())
  local staging = circuitConfig.stagingForRace(definition, M.trackFlowState.useAltRoute)
  if trackFlowState.mCachedPlayerStagingSpotNameLevel == getCurrentLevelIdentifier()
    and trackFlowState.mCachedPlayerStagingSpotNameRace == M.getCompetitiveRaceId() then
    return trackFlowState.mCachedPlayerStagingSpotName
  end
  return staging and staging.playerSpot
end

function M.getPlayerStagingSpotName()
  return getPlayerStagingSpotNameForLevel()
end

--- Override only the selected race's player spot name; the sites document still comes from data.
function M.setPlayerStagingSpotNameOverride(name)
  if name == nil or name == "" then
    trackFlowState.mCachedPlayerStagingSpotName = nil
    trackFlowState.mCachedPlayerStagingSpotNameLevel = nil
    return
  end
  trackFlowState.mCachedPlayerStagingSpotName = name
  trackFlowState.mCachedPlayerStagingSpotNameLevel = getCurrentLevelIdentifier() or ""
  trackFlowState.mCachedPlayerStagingSpotNameRace = M.getCompetitiveRaceId()
end

local function sess()
  return overhaul_events_session
end

local core_groundMarkers = require("core/groundMarkers")

local function getStagingSpotHalfExtents(spot)
  if not spot or not spot.scl then return nil end
  local s = spot.scl
  return { (s[1] or 3) * 0.5, (s[2] or 6) * 0.5, (s[3] or 2) * 0.5 }
end

local function isPointInStagingSpot(spot, wx, wy, wz)
  if not spot or not spot.pos or not spot.scl then return false end
  local he = getStagingSpotHalfExtents(spot)
  if not he then return false end
  local px, py, pz = spot.pos[1], spot.pos[2], spot.pos[3]
  local sx, sy, sz = he[1], he[2], he[3]
  local dx, dy, dz = wx - px, wy - py, wz - pz
  if spot.rot and spot.rot[4] then
    local ok, localPt = pcall(function()
      local race = spot.rot
      local invQ = quat(-(race[1] or 0), -(race[2] or 0), -(race[3] or 0), race[4] or 1)
      return invQ * vec3(dx, dy, dz)
    end)
    if ok and localPt then
      return math.abs(localPt.x) <= sx and math.abs(localPt.y) <= sy and math.abs(localPt.z) <= sz
    end
  end
  return math.abs(dx) <= sx and math.abs(dy) <= sy and math.abs(dz) <= sz
end

local function isPointInStagingSpotWithPadding(spot, wx, wy, wz, pad)
  if not spot or not spot.pos or not spot.scl then return false end
  local he = getStagingSpotHalfExtents(spot)
  if not he then return false end
  local p = pad or 0
  local px, py, pz = spot.pos[1], spot.pos[2], spot.pos[3]
  local sx, sy, sz = he[1] + p, he[2] + p, he[3] + p
  local dx, dy, dz = wx - px, wy - py, wz - pz
  if spot.rot and spot.rot[4] then
    local ok, localPt = pcall(function()
      local race = spot.rot
      local invQ = quat(-(race[1] or 0), -(race[2] or 0), -(race[3] or 0), race[4] or 1)
      return invQ * vec3(dx, dy, dz)
    end)
    if ok and localPt then
      return math.abs(localPt.x) <= sx and math.abs(localPt.y) <= sy and math.abs(localPt.z) <= sz
    end
  end
  return math.abs(dx) <= sx and math.abs(dy) <= sy and math.abs(dz) <= sz
end

function M.loadPlayerStagingSpot()
  local definition = M.getCompetitiveRaceDefinition(M.getCompetitiveRaceId())
  local staging = circuitConfig.stagingForRace(definition, M.trackFlowState.useAltRoute)
  if staging then
    staging = {sitesFile = staging.sitesFile, playerSpot = getPlayerStagingSpotNameForLevel(),
      aiSpots = staging.aiSpots, stagingPrefix = staging.stagingPrefix}
  end
  local loaded, reason = circuitConfig.loadStaging(staging)
  return loaded and loaded.playerSpot, reason
end

function M.isPlayerInStagingSpot(spot)
  if not spot or not spot.pos or not spot.scl then return false end
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then return false end
  local pos = playerVeh:getPosition()
  return isPointInStagingSpot(spot, pos.x, pos.y, pos.z)
end

local function isPlayerInTrackParkingCommitSpot(spot)
  if not spot or not spot.pos or not spot.scl then return false end
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then return false end
  local pos = playerVeh:getPosition()
  return isPointInStagingSpotWithPadding(spot, pos.x, pos.y, pos.z, TRACK_GRID_PARKING_COMMIT_PADDING_M)
end

function M.isPlayerInTrackParkingCommitArea()
  if not trackFlowState.mPlayerStagingSpot then return false end
  return isPlayerInTrackParkingCommitSpot(trackFlowState.mPlayerStagingSpot)
end

function M.clearPlayerStagingCornerMarkers()
  for _, obj in ipairs(mPlayerStagingCornerMarkers) do
    pcall(function()
      if obj and obj.delete then obj:delete() end
    end)
  end
  table.clear(mPlayerStagingCornerMarkers)
end

local function createStagingCornerMarker(markerScale, spotQuat, rotationDegrees, index, corner, baseName)
  local marker = createObject("TSStatic")
  if not marker then return nil end
  marker.shapeName = "art/shapes/interface/position_marker.dae"
  marker.scale = vec3(markerScale, markerScale, markerScale)
  marker.useInstanceRenderData = true
  marker.canSave = false
  if ColorF and ColorF(1, 0.5, 0, 1) and (ColorF(1, 0.5, 0, 1):asLinear4F()) then
    marker.instanceColor = ColorF(1, 0.5, 0, 1):asLinear4F()
  else
    marker:setField("instanceColor", 0, "1 0.5 0 1")
  end
  local rot = spotQuat
  if quatFromEuler and rot then
    local cornerZ = quatFromEuler(0, 0, math.rad(rotationDegrees or 0))
    rot = rot * cornerZ
  end
  if rot then
    marker:setPosRot(corner[1], corner[2], corner[3] + 0.1, rot.x, rot.y, rot.z, rot.w)
  else
    marker:setPosRot(corner[1], corner[2], corner[3] + 0.1, 0, 0, 0, 0)
  end
  marker:registerObject(baseName .. index)
  return marker
end

function M.showPlayerStagingCornerMarkers(spot)
  M.clearPlayerStagingCornerMarkers()
  if not spot or not spot.pos or not spot.scl then return end
  if not createObject then return end
  local he = getStagingSpotHalfExtents(spot)
  if not he then return end
  local sx, sy, sz = he[1], he[2], he[3]
  local px, py, pz = spot.pos[1], spot.pos[2], spot.pos[3]
  local spotQuat
  local xVec, yVec, zVec = vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1)
  if spot.rot and spot.rot[4] then
    local ok, q = pcall(function()
      local race = spot.rot
      return quat(race[1] or 0, race[2] or 0, race[3] or 0, race[4] or 1)
    end)
    if ok and q then
      spotQuat = q
      xVec = q * vec3(1, 0, 0)
      yVec = q * vec3(0, 1, 0)
      zVec = q * vec3(0, 0, 1)
    end
  end
  local corners = {
    { px - xVec.x * sx + yVec.x * sy, py - xVec.y * sx + yVec.y * sy, pz - xVec.z * sx + yVec.z * sy },
    { px + xVec.x * sx + yVec.x * sy, py + xVec.y * sx + yVec.y * sy, pz + xVec.z * sx + yVec.z * sy },
    { px + xVec.x * sx - yVec.x * sy, py + xVec.y * sx - yVec.y * sy, pz + xVec.z * sx - yVec.z * sy },
    { px - xVec.x * sx - yVec.x * sy, py - xVec.y * sx - yVec.y * sy, pz - xVec.z * sx - yVec.z * sy },
  }
  local cornerZDeg = { 90, 180, 270, 0 }
  local markerScale = math.min(spot.scl[1] or 3, spot.scl[2] or 6) * 0.2
  if markerScale < 0.15 then markerScale = 0.15 end
  if markerScale > 1.5 then markerScale = 1.5 end
  local baseName = "freeroamTrackFlow_stageCorner_" .. tostring(os and os.time and os.time() or 0) .. "_"
  for i, c in ipairs(corners) do
    local ok, marker = pcall(createStagingCornerMarker, markerScale, spotQuat, cornerZDeg[i], i, c, baseName)
    if ok and marker then table.insert(mPlayerStagingCornerMarkers, marker) end
  end
end

function M.getPlayerStagingSpot()
  return trackFlowState.mPlayerStagingSpot
end

function M.setPlayerStagingSpot(spot)
  trackFlowState.mPlayerStagingSpot = spot
  trackFlowState.mPlayerStagingSpotLoadLevel = getCurrentLevelIdentifier()
  trackFlowState.mPlayerStagingSpotLoadRace = M.getCompetitiveRaceId()
  trackFlowState.mPlayerStagingSpotLoadAttempted = true
end

function M.setPlayerStagingSpotNil()
  trackFlowState.mPlayerStagingSpot = nil
  trackFlowState.mPlayerStagingSpotLoadAttempted = false
  trackFlowState.mPlayerStagingSpotLoadLevel = nil
end

function M.ensurePlayerStagingSpotLoaded()
  local levelId = getCurrentLevelIdentifier()
  if trackFlowState.mPlayerStagingSpotLoadLevel ~= levelId
    or trackFlowState.mPlayerStagingSpotLoadRace ~= M.getCompetitiveRaceId() then M.setPlayerStagingSpotNil() end
  if trackFlowState.mPlayerStagingSpot or trackFlowState.mPlayerStagingSpotLoadAttempted then return end
  trackFlowState.mPlayerStagingSpotLoadLevel = levelId
  trackFlowState.mPlayerStagingSpotLoadRace = M.getCompetitiveRaceId()
  trackFlowState.mPlayerStagingSpotLoadAttempted = true
  local spot = M.loadPlayerStagingSpot()
  if spot then M.setPlayerStagingSpot(spot) end
end

-- Race staging policy -------------------------------------------------------------------------------

function M.raceAllowsAiSpawn(race)
  local aiRacers = overhaul_events_aiRacers
  if not race or not aiRacers then return false end
  local cfg = aiRacers.getMergedConfigForRace(race)
  if not cfg or cfg.enabled == false then return false end
  if race.spawnSameVehicleAsPlayer or cfg.spawnSameVehicleAsPlayer then return true end
  local n = race.aiCount or cfg.maxSpawnCount or cfg.aiCount
  if type(n) == "number" and n > 0 then return true end
  if type(cfg.vehiclePool) == "table" then return true end
  return false
end

function M.getCompetitiveRaceDefinition(raceName)
  local levelId = getCurrentLevelIdentifier()
  if trackFlowState.definitionLevel ~= levelId then
    trackFlowState.definitions = circuitConfig.loadRaceDefinitions(levelId)
    trackFlowState.definitionLevel = levelId
    M.trackFlowState.raceName = nil
    M.trackFlowState.useAltRoute = false
  end
  return (trackFlowState.definitions or {})[raceName]
end

function M.getCompetitiveRaceId()
  M.getCompetitiveRaceDefinition(nil)
  local session = sess()
  local id = session.mActiveRace or session.staged or M.trackFlowState.raceName
  if id then return M.raceUsesSanctionedParkingStaging(id) and id or nil end
  local selected
  for name, definition in pairs(trackFlowState.definitions or {}) do
    if definition.competitive and definition.defaultCompetitive then
      if selected then return nil end
      selected = name
    end
  end
  return selected
end

-- Select before navigation, teleport or AI spawn. No implicit choice between independent circuits.
function M.setCompetitiveRace(raceName, useAltRoute)
  if not M.raceUsesSanctionedParkingStaging(raceName) then
    return false, "Race has no competitive capability: " .. tostring(raceName)
  end
  local session = sess()
  if session.mActiveRace and session.mActiveRace ~= raceName then return false, "A different race is active" end
  if session.staged and session.staged ~= raceName then return false, "A different race is staged" end
  local definition = M.getCompetitiveRaceDefinition(raceName)
  local course, reason = circuitConfig.routeForRace(definition, useAltRoute)
  if not course then return false, reason end
  local staging = circuitConfig.stagingForRace(definition, useAltRoute)
  local loaded, reason = circuitConfig.loadStaging(staging)
  if not loaded then return false, reason end
  if M.trackFlowState.raceName ~= raceName or M.trackFlowState.useAltRoute ~= (useAltRoute == true) then
    M.resetTrackGridFlowFlags()
    local aiRacers = overhaul_events_aiRacers
    if aiRacers then aiRacers.clearSpawned() end
    trackFlowState.mCompetitiveCountdownGeneration = trackFlowState.mCompetitiveCountdownGeneration + 1
    M.setPlayerStagingSpotNil()
    M.clearPlayerStagingCornerMarkers()
  end
  M.trackFlowState.raceName = raceName
  M.trackFlowState.useAltRoute = useAltRoute == true
  return true
end

function M.trackRaceForAi(raceName)
  local id = raceName or M.getCompetitiveRaceId()
  if not id then return nil end
  local definition = M.getCompetitiveRaceDefinition(id)
  local races = sess().races
  local race = races and races[id] or definition and definition.race
  if not race then return nil end
  local useAlt = M.trackFlowState.useAltRoute and race.altRoute
  local selected = useAlt and race.altRoute or race
  selected._competitiveRaceId = id
  selected._competitiveRouteType = useAlt and "alt" or "main"
  return selected
end

-- Commerce can use this capability for ride-along admission instead of inspecting event IDs.
function M.getCompetitiveRaceCapabilities(raceName)
  local definition = M.getCompetitiveRaceDefinition(raceName)
  if not definition or not definition.competitive then return nil end
  return {competitive = true, racingTeam = definition.racingTeam, staging = definition.staging}
end

function M.isSanctionedCareerGoToRaceActive()
  return M.trackFlowState.sanctionedCareerGoToRaceActive == true
end

function M.isSanctionedRaceStagingUiActive()
  return trackFlowState.mSanctionedParkingUiPhase ~= "hidden"
end

function M.raceUsesSanctionedParkingStaging(raceName)
  local definition = M.getCompetitiveRaceDefinition(raceName)
  return definition ~= nil and definition.competitive == true
end

function M.shouldBlockFreeroamStagingPractice(raceName)
  if not M.isSanctionedRaceStagingUiActive() then return false end
  return M.raceUsesSanctionedParkingStaging(raceName)
end

function M.resolveEffectiveStagingRace(raceName, race)
  if M.raceUsesSanctionedParkingStaging(raceName) then return M.trackRaceForAi(raceName) or race end
  return race
end

function M.resolveStagingHudTotalLaps(raceName, sess, hotlapRaceName, effectiveStagingRace, isLapRace)
  if sess.freeroamPracticeStaging then return 0 end
  if hotlapRaceName == raceName then return 0 end
  local base = isLapRace and M.getDisplayTotalLapsForRace(effectiveStagingRace) or 0
  if not M.isSanctionedCareerGoToRaceActive() then
    if M.raceUsesSanctionedParkingStaging(raceName) then return 0 end
    return base
  end
  if M.raceUsesSanctionedParkingStaging(raceName) then
    local sr = overhaul_events_fre_sanctionedRacing
    local lc = sr and sr.getSanctionedOfferLapCount()
    if lc and lc > 0 then return lc end
  end
  return base
end

function M.resolveRacingHudTotalLaps(mActiveRaceName, sess, effectiveRace, isLapRace)
  local totalLapsVal = isLapRace and M.getDisplayTotalLapsForRace(effectiveRace) or 0
  if sess.freeroamPracticeStaging then return 0 end
  local sr = overhaul_events_fre_sanctionedRacing
  -- When track flow didn't arm suppressFrePayouts yet, avoid forcing 0 laps (hotlap-style HUD): use committed offer or race data.
  if M.raceUsesSanctionedParkingStaging(mActiveRaceName) and sr and not sr.shouldSuppressFrePayouts() then
    local lc = sr.getCommittedRacingSanctionedOfferLapCount(mActiveRaceName)
    if lc and lc > 0 then return lc end
    return totalLapsVal
  end
  return totalLapsVal
end

function M.setSanctionedCareerGoToRaceActive(v)
  M.trackFlowState.sanctionedCareerGoToRaceActive = v == true
end

function M.clearSanctionedCareerGoToRaceActive()
  M.trackFlowState.sanctionedCareerGoToRaceActive = false
end

function M.isRacingTeamProxyRaceActive()
  return M.trackFlowState.racingTeamProxyRaceActive == true
end

function M.isRacingTeamProxyRaceSessionActive()
  return M.trackFlowState.racingTeamProxyRaceSession == true
end

--- Sanctioned phone flow OR racing-team proxy staging (shared grid / countdown gates).
function M.isTrackGridCareerStagingGateActive()
  return M.trackFlowState.sanctionedCareerGoToRaceActive == true or M.trackFlowState.racingTeamProxyRaceActive == true
end

-- Proxy race lifetime -------------------------------------------------------------------------------

function M.clearRacingTeamProxyParkingState()
  -- Staging ended before green; once the race drives the team car this does nothing.
  if overhaul_events_aiRacers and overhaul_events_aiRacers.releaseTeamCarFromGrid then
    overhaul_events_aiRacers.releaseTeamCarFromGrid()
  end
  M.trackFlowState.racingTeamProxyRaceActive = false
  M.trackFlowState.racingTeamProxyBusinessId = nil
  M.trackFlowState.racingTeamProxyFleetVehicleId = nil
  M.trackFlowState.racingTeamProxyAiPoolRefHp = nil
  M.trackFlowState.racingTeamProxyAiPoolMinHp = nil
  M.trackFlowState.racingTeamProxyAiPoolBracketOnly = false
  M.trackFlowState.racingTeamProxyAiDifficultyT = nil
  trackFlowState.mRacingTeamProxyNextAttemptClock = nil
  trackFlowState.mRacingTeamProxyStagingTeleportJobActive = false
  M.exitRacingTeamProxyStagingLoadingScreen()
  restoreRacingTeamProxySpectatorUiAfterMinimal()
end

--- Load-in failed (no opponents spawned): return player to pre-race position, end staging, keep the proxy armed for a retry.
function M.abortRacingTeamProxyStagingLoadIn(reason)
  if not M.trackFlowState.racingTeamProxyRaceActive then return end
  racingTeamProxyResetAiSpawnBookkeeping()
  local rbd = overhaul_career_business_racingTeam_rideAlong
  if rbd and rbd.hasPreRaceWorldState() then pcall(function()
    rbd.restorePreRaceWorldState()
  end) end
  M.trackFlowState.inTrackFlowContext = false
  M.clearRacingTeamProxyParkingState()
  overhaul_events_utils.displayMessage("Failed to load opponents. Try again.", 5)
end

--- Call when track race starts (beginFreeroamRace): parking proxy ends, session cleanup runs at race exit.
function M.onTrackRaceBeganFromRacingTeamProxy()
  if not M.trackFlowState.racingTeamProxyRaceActive then return end
  local bid = M.trackFlowState.racingTeamProxyBusinessId
  M.relayRacingTeamProxyOverlay({
    visible = true,
    businessId = bid and tostring(bid) or "",
    inRace = true,
    playerTeleportedToTeamCar = true,
  })
  refreshProxySpectatorUiIfMinimal()
  M.trackFlowState.racingTeamProxyRaceSession = true
  M.trackFlowState.racingTeamProxySessionBusinessId = M.trackFlowState.racingTeamProxyBusinessId
  M.trackFlowState.racingTeamProxySessionFleetVehicleId = M.trackFlowState.racingTeamProxyFleetVehicleId
  M.trackFlowState.racingTeamProxyRaceActive = false
  M.trackFlowState.racingTeamProxyBusinessId = nil
  M.trackFlowState.racingTeamProxyFleetVehicleId = nil
  M.trackFlowState.racingTeamProxyAiPoolRefHp = nil
  M.trackFlowState.racingTeamProxyAiPoolMinHp = nil
  M.trackFlowState.racingTeamProxyAiPoolBracketOnly = false
  M.trackFlowState.racingTeamProxyAiDifficultyT = nil
end

--- Returns { businessId, fleetVehicleId } once, then clears session markers (for post-race cleanup).
function M.takeRacingTeamProxyRaceSessionCleanup()
  if not M.trackFlowState.racingTeamProxyRaceSession then return nil end
  local out = {
    businessId = M.trackFlowState.racingTeamProxySessionBusinessId,
    fleetVehicleId = M.trackFlowState.racingTeamProxySessionFleetVehicleId,
  }
  M.trackFlowState.racingTeamProxyRaceSession = false
  M.trackFlowState.racingTeamProxySessionBusinessId = nil
  M.trackFlowState.racingTeamProxySessionFleetVehicleId = nil
  M.relayRacingTeamProxyOverlay({ visible = false })
  return out
end

--- Read { businessId, fleetVehicleId } without consuming the proxy session (for deferred cinematic finish).
function M.getRacingTeamProxyRaceSessionSnapshot()
  if not M.trackFlowState.racingTeamProxyRaceSession then return nil end
  return {
    businessId = M.trackFlowState.racingTeamProxySessionBusinessId,
    fleetVehicleId = M.trackFlowState.racingTeamProxySessionFleetVehicleId,
  }
end

function M.getDisplayTotalLapsForRace(race)
  if not sess().freeroamPracticeStaging then
    local forced = tonumber(M.trackFlowState.sanctionedRaceLapCount)
    if forced and forced > 0 and race == M.trackRaceForAi() then
      local sr = overhaul_events_fre_sanctionedRacing
      if sr and sr.shouldSuppressFrePayouts() then return math.floor(forced) end
    end
  end
  if not race then return 0 end
  local lc = tonumber(race.lapCount)
  if lc and lc > 0 then return math.floor(lc) end
  local rs = race.session
  local slc = rs and tonumber(rs.lapCount)
  if slc and slc > 0 then return math.floor(slc) end
  if race.hotlap then return 3 end
  if race.checkpointRoad then return 1 end
  return 0
end

function M.spawnedTrackAiCount()
  local aiRacers = overhaul_events_aiRacers
  if not aiRacers then return 0 end
  local ids = aiRacers.getSpawnedVehicleIds()
  if not ids then return 0 end
  return #ids
end

-- Grid cleanup --------------------------------------------------------------------------------------

function M.resetTrackGridFlowFlags()
  trackFlowState.mTrackGridParkingAiSpawnStarted = false
  trackFlowState.mCompetitiveAwaitingAiSpawn = false
  trackFlowState.mTrackGridAiSpawnWaitDeadline = nil
end

function M.cancelCompetitiveGridFlow()
  trackFlowState.mCompetitiveCountdownCancel = true
  trackFlowState.mCompetitiveCountdownJobActive = false
  M.resetTrackGridFlowFlags()
  guihooks.trigger("ScenarioFlashMessage", { msg = "", ttl = 0, clearQueue = true })
  local aiRacers = overhaul_events_aiRacers
  if aiRacers then aiRacers.setPlayerFreeze(false) end
end

function M.clearSanctionedNavigateVisuals()
  M.clearPlayerStagingCornerMarkers()
  core_groundMarkers.resetAll()
end

function M.leaveTrackFlowAfterRace()
  trackFlowState.mSanctionedParkingUiPhase = "hidden"
  trackFlowState.mSanctionedParkingUiPushClock = nil
  trackFlowState.mSanctionedParkingLiveRefreshClock = nil
  statePush.refresh("SanctionedParkingStagingUi", { visible = false })
  M.relayRacingTeamProxyOverlay({ visible = false })
  M.trackFlowState.inTrackFlowContext = false
  M.clearSanctionedCareerGoToRaceActive()
  M.trackFlowState.sanctionedPoolRefPw = nil
  M.trackFlowState.sanctionedPoolRefHp = nil
  M.trackFlowState.sanctionedRaceLapCount = nil
  M.trackFlowState.useAltRoute = false
  M.trackFlowState.raceName = nil
  M.trackFlowState.racingTeamProxyRaceSession = false
  M.trackFlowState.racingTeamProxySessionBusinessId = nil
  M.trackFlowState.racingTeamProxySessionFleetVehicleId = nil
  M.clearRacingTeamProxyParkingState()
  M.resetTrackGridFlowFlags()
  M.setPlayerStagingSpotNil()
  M.clearSanctionedNavigateVisuals()
end

function M.resetForCareerChange()
  trackFlowState.mCompetitiveCountdownGeneration = trackFlowState.mCompetitiveCountdownGeneration + 1
  trackFlowState.mCompetitiveCountdownCancel = true
  trackFlowState.mCompetitiveCountdownJobActive = false
  M.leaveTrackFlowAfterRace()
end

function M.isVehicleEligibleForCompetitiveTrack(spawnedId)
  if not overhaul_career_career.isActive() then return true end
  if overhaul_career_economy_cheats.isCheatsMode() then return true end
  local function checkId(id)
    if not id then return false end
    local businessId, vehicleId = overhaul_career_business_fleet.getBusinessVehicleFromSpawnedId(id)
    if businessId and vehicleId then return true end
    local invId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(id)
    if invId then
      local vehicle = overhaul_career_garage_inventory.getVehicles()[invId]
      if vehicle and not vehicle.loanType then return true end
    end
    return false
  end
  if checkId(spawnedId) then return true end
  local currentId = be:getPlayerVehicleID(0)
  if currentId and currentId ~= spawnedId then
    if checkId(currentId) then return true end
  end
  return false
end

local trackFlowGrid = require("overhaul/events/competitiveTrackFlow/trackFlowGrid").create({
  M = M,
  TRACK_GRID_STAGE_STOP_MPH = TRACK_GRID_STAGE_STOP_MPH,
  TRACK_GRID_AI_SPAWN_WAIT_SEC = TRACK_GRID_AI_SPAWN_WAIT_SEC,
  tf = trackFlowState,
  refreshProxySpectatorUiIfMinimal = refreshProxySpectatorUiIfMinimal,
  sess = sess,
  core_groundMarkers = core_groundMarkers,
  isPlayerInTrackParkingCommitSpot = isPlayerInTrackParkingCommitSpot,
})
local getVehicleSpeedMph = trackFlowGrid.getVehicleSpeedMph

-- Sanctioned parking UI -----------------------------------------------------------------------------

local function pushSanctionedParkingGui()
  if trackFlowState.mSanctionedParkingUiPhase == "hidden" then
    statePush.refresh("SanctionedParkingStagingUi", { visible = false })
    return
  end
  statePush.refresh("SanctionedParkingStagingUi", {
    visible = true,
    payload = M.buildSanctionedParkingUiPayload(),
  })
end

function M.buildSanctionedParkingUiPayload()
  local sr = overhaul_events_fre_sanctionedRacing
  local pw, pwSource = nil, nil
  local ar = overhaul_events_aiRacers
  if ar then
    pw, pwSource = ar.getPlayerVehiclePwForStagingUi()
  end
  local out = {
    phase = trackFlowState.mSanctionedParkingUiPhase,
    awaitingSpawn = trackFlowState.mCompetitiveAwaitingAiSpawn,
    spawnedAiCount = M.spawnedTrackAiCount(),
    playerPw = pw,
    playerPwSource = pwSource,
  }
  if not sr then return out end
  local state = overhaul_events_fre_state.getState()
  local now = state and tonumber(state.simTime) or 0
  local snap = sr.getOfferUiSnapshot(now)
  if not snap then
    local raceForAiEarly = M.trackRaceForAi()
    out.requiresAiSpawn = raceForAiEarly and M.raceAllowsAiSpawn(raceForAiEarly) or false
    return out
  end
  out.raceLabel = snap.raceLabel
  out.stageNumber = tonumber(snap.stageNumber) or 1
  out.hpBracketBranch = snap.hpBracketBranch
  out.classPwMin = tonumber(snap.classPwMin)
  out.classPwMax = tonumber(snap.classPwMax)
  local raceClassSource = out.classPwMin or out.classPwMax
  local raceClassLabelFormatted =
    formatSanctionedClassWithBucket(snap.hpBracketLabel, snap.hpBracketBranch, raceClassSource)
  out.hpBracketLabel = raceClassLabelFormatted ~= "" and raceClassLabelFormatted or snap.hpBracketLabel
  out.raceClassLabel = out.hpBracketLabel
  if type(pw) == "number" and pw > 0 then
    local rawPlayerClass = sr.getSanctionedPwBracketLabelForPw(pw)
    local playerClassFormatted = formatSanctionedClassWithBucket(rawPlayerClass, snap.hpBracketBranch, pw)
    out.playerSanctionedClassLabel = playerClassFormatted ~= "" and playerClassFormatted or rawPlayerClass
  end
  out.lapCount = tonumber(snap.lapCount) or 0
  out.payoutFirst = snap.payoutFirst
  out.payoutSecond = snap.payoutSecond
  out.payoutThird = snap.payoutThird
  local raceForAi = M.trackRaceForAi()
  out.requiresAiSpawn = raceForAi and M.raceAllowsAiSpawn(raceForAi) or false
  return out
end

function M.sanctionedParkingAbortStaging()
  if trackFlowState.mSanctionedParkingUiPhase == "hidden" then return end
  trackFlowState.mSanctionedParkingUiPhase = "hidden"
  trackFlowState.mSanctionedParkingUiPushClock = nil
  trackFlowState.mSanctionedParkingLiveRefreshClock = nil
  statePush.refresh("SanctionedParkingStagingUi", { visible = false })
  local aiRacers = overhaul_events_aiRacers
  if aiRacers then aiRacers.clearSpawned() end
  M.cancelCompetitiveGridFlow()
end

function M.clearSanctionedParkingStagingUi()
  trackFlowState.mSanctionedParkingUiPhase = "hidden"
  trackFlowState.mSanctionedParkingUiPushClock = nil
  trackFlowState.mSanctionedParkingLiveRefreshClock = nil
  statePush.refresh("SanctionedParkingStagingUi", { visible = false })
end

function M.sanctionedParkingStageAndSpawn()
  if not M.trackFlowState.sanctionedCareerGoToRaceActive then return false end
  if trackFlowState.mSanctionedParkingUiPhase ~= "prompt" then return false end
  if
    not trackFlowState.mPlayerStagingSpot or not isPlayerInTrackParkingCommitSpot(trackFlowState.mPlayerStagingSpot)
  then
    return false
  end
  if overhaul_events_utils.isPlayerInPursuit() then
    overhaul_events_utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
    return false
  end
  local aiRacers = overhaul_events_aiRacers
  if aiRacers then aiRacers.setPlayerFreeze(true) end
  trackFlowState.mSanctionedParkingUiPhase = "spawned_ready"
  M.prepareFreeroamAiForTrack(nil, true)
  pushSanctionedParkingGui()
  return true
end

function M.sanctionedParkingStartEvent()
  if not M.trackFlowState.sanctionedCareerGoToRaceActive then return false end
  if trackFlowState.mSanctionedParkingUiPhase ~= "spawned_ready" then return false end
  local pv = be:getPlayerVehicle(0)
  if not pv then return false end
  local vid = pv:getID()
  if
    not trackFlowState.mPlayerStagingSpot or not isPlayerInTrackParkingCommitSpot(trackFlowState.mPlayerStagingSpot)
  then
    return false
  end
  if overhaul_events_utils.isPlayerInPursuit() then
    overhaul_events_utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
    return false
  end
  local raceForAi = M.trackRaceForAi()
  if raceForAi and M.raceAllowsAiSpawn(raceForAi) then
    if trackFlowState.mCompetitiveAwaitingAiSpawn then
      overhaul_events_utils.displayMessage("Wait for AI to finish loading.", 3)
      return false
    end
    if M.spawnedTrackAiCount() == 0 then
      overhaul_events_utils.displayMessage("No AI on grid. Try staging again.", 4)
      return false
    end
  end
  trackFlowState.mSanctionedParkingUiPhase = "hidden"
  trackFlowState.mSanctionedParkingUiPushClock = nil
  trackFlowState.mSanctionedParkingLiveRefreshClock = nil
  statePush.refresh("SanctionedParkingStagingUi", { visible = false })
  local ok = M.tryCommitTrackGridStaging(vid, { skipAiPrereq = true })
  if not ok then
    trackFlowState.mSanctionedParkingUiPhase = "spawned_ready"
    pushSanctionedParkingGui()
  end
  return ok
end

-- Parking triggers ----------------------------------------------------------------------------------

function M.beamngTrigger_competitiveHub(data, event, raceName)
  raceName = raceName or data.raceName
  if event == "exit" and raceName ~= M.getCompetitiveRaceId() then return end
  if not M.isVehicleEligibleForCompetitiveTrack(data.subjectID) then return end
  local aiRacers = overhaul_events_aiRacers
  if event == "enter" then
    if not aiRacers or not aiRacers.levelHasAiRacingConfig() then return end
    local useAltRoute = raceName == M.getCompetitiveRaceId() and M.trackFlowState.useAltRoute
    local ok, reason = M.setCompetitiveRace(raceName, useAltRoute)
    if not ok then log("W", "competitiveTrackFlow", tostring(reason)); return end
    M.trackFlowState.inTrackFlowContext = true
    M.ensurePlayerStagingSpotLoaded()
    sess().saveGameState = true
    core_gamestate.requestGameState()
    local levelId = getCurrentLevelIdentifier()
    local bc = overhaul_career_business_racingTeam_raceFlow
    -- Racing-team proxy requests exist only in career.
    if levelId and overhaul_career_career.isActive() then
      local req, bid = bc.findProxyDriverRaceRequestForLevel(levelId)
      if req and bid and req.racingTeamProxyRace and req.raceName == M.getCompetitiveRaceId()
        and not M.trackFlowState.sanctionedCareerGoToRaceActive then
        M.trackFlowState.racingTeamProxyRaceActive = true
        M.trackFlowState.racingTeamProxyBusinessId = bid
        M.trackFlowState.racingTeamProxyFleetVehicleId = tonumber(req.fleetVehicleId) or req.fleetVehicleId
        syncRacingTeamProxyBracketFromRequest(req)
        local lc = tonumber(req.lapCount)
        if lc and lc > 0 then M.trackFlowState.sanctionedRaceLapCount = lc end
        local racingTeam = req.raceRouteType
        if type(racingTeam) == "string" and racingTeam:lower() == "alt" then M.trackFlowState.useAltRoute = true end
      end
    end
  elseif event == "exit" then
    if not sess().mActiveRace then
      M.trackFlowState.inTrackFlowContext = false
      M.setPlayerStagingSpotNil()
      core_groundMarkers.resetAll()
      if not M.trackFlowState.racingTeamProxyRaceSession then
        M.clearRacingTeamProxyParkingState()
        M.sanctionedParkingAbortStaging()
      end
    end
  end
end

-- Proxy parking and teleport ------------------------------------------------------------------------

local function proxyParkingRequestReady()
  local clk = (os and os.clock) and os.clock() or 0
  if
    trackFlowState.mRacingTeamProxyNextAttemptClock and (clk - trackFlowState.mRacingTeamProxyNextAttemptClock) < 0.35
  then
    return
  end
  trackFlowState.mRacingTeamProxyNextAttemptClock = clk

  local levelId = getCurrentLevelIdentifier()
  local parkingRaceFlow = overhaul_career_business_racingTeam_raceFlow
  if not levelId or not parkingRaceFlow then return end
  local proxyRaceRequest, businessId = parkingRaceFlow.findProxyDriverRaceRequestForLevel(levelId)
  if not proxyRaceRequest or not businessId or proxyRaceRequest.raceName ~= M.getCompetitiveRaceId() then
    M.clearRacingTeamProxyParkingState()
    return
  end

  return true
end

local function proxyVehicleIdEqual(a, b)
  return (tonumber(a) or a) == (tonumber(b) or b) or tostring(a) == tostring(b)
end

local function teleportProxyPlayerToStaging(businessFleet, proxyBusinessId, fleetVehicleId)
  local okSpot = businessFleet.teleportSpawnedBusinessVehicleToSpot(proxyBusinessId, fleetVehicleId, trackFlowState.mPlayerStagingSpot)
  if okSpot then
    local spawnedTeamVehicleId = businessFleet.getSpawnedVehicleId(proxyBusinessId, fleetVehicleId)
    local spawnedTeamVehicle = spawnedTeamVehicleId and be:getObjectByID(spawnedTeamVehicleId)
    if spawnedTeamVehicle then be:enterVehicle(0, spawnedTeamVehicle) end
    M.relayRacingTeamProxyOverlay({
      visible = true,
      businessId = proxyBusinessId and tostring(proxyBusinessId) or "",
      inRace = false,
      playerTeleportedToTeamCar = true,
    })
    refreshProxySpectatorUiIfMinimal()
  end
  return okSpot == true
end

local function stageProxyTeleportOutsideTeamCar(businessFleet, proxyBusinessId, fleetVehicleId, playerVehicleId, rideAlong)
  if trackFlowState.mRacingTeamProxyStagingTeleportJobActive then return end
  if not M.isPlayerInTrackParkingCommitArea() then return end
  if getVehicleSpeedMph(playerVehicleId) > TRACK_GRID_STAGE_STOP_MPH then return end
  if rideAlong and not rideAlong.hasPreRaceWorldState() then rideAlong.savePreRaceWorldState() end
  local useStagingOverlay = racingTeamProxyUseTeamLoadingOverlay()
  -- Racing-team proxy only: loading overlay stays up through teleport + AI spawn (same tick never paints; yield first).
  if useStagingOverlay then
    trackFlowState.mRacingTeamProxyStagingTeleportJobActive = true
    M.enterRacingTeamProxyStagingLoadingEarly()
    core_jobsystem.create(function(job)
      job.sleep(RACING_TEAM_PROXY_TEAM_LOADING_PAINT_DELAY_SEC)
      local teleportedOk = false
      local ok, err = pcall(function()
        teleportedOk = teleportProxyPlayerToStaging(businessFleet, proxyBusinessId, fleetVehicleId)
      end)
      if not ok then
        log("E", "competitiveTrackFlow", "racing team proxy staging teleport: " .. tostring(err))
      end
      if teleportedOk then
        pcall(function()
          racingTeamProxyRunStagingTailAfterPlayerInTeamCar(job)
        end)
      end
      refreshProxySpectatorUiIfMinimal()
      trackFlowState.mRacingTeamProxyStagingTeleportJobActive = false
      trackFlowState.mRacingTeamProxyNextAttemptClock = nil
      M.onUpdateRacingTeamProxyParkingLoop()
    end)
    return
  end
  teleportProxyPlayerToStaging(businessFleet, proxyBusinessId, fleetVehicleId)
  refreshProxySpectatorUiIfMinimal()
  trackFlowState.mRacingTeamProxyNextAttemptClock = nil
  M.onUpdateRacingTeamProxyParkingLoop()
  return
end

local function commitProxyParkingTeamCar(playerVehicleId)
  if trackFlowState.mRacingTeamProxyStagingTeleportJobActive then return end

  if not M.isPlayerInTrackParkingCommitArea() then return end
  if getVehicleSpeedMph(playerVehicleId) > TRACK_GRID_STAGE_STOP_MPH then return end

  local raceForAi = M.trackRaceForAi()
  if raceForAi and M.raceAllowsAiSpawn(raceForAi) then
    if not trackFlowState.mTrackGridParkingAiSpawnStarted and M.spawnedTrackAiCount() == 0 then
      local refPw = nil
      local aiRacers = overhaul_events_aiRacers
      if
        type(M.trackFlowState.racingTeamProxyAiPoolRefHp) == "number"
        and M.trackFlowState.racingTeamProxyAiPoolRefHp > 0
      then
        refPw = M.trackFlowState.racingTeamProxyAiPoolRefHp
      elseif aiRacers then
        refPw = select(1, aiRacers.getPlayerVehiclePwForStagingUi())
      end
      M.prepareFreeroamAiForTrack(refPw, true)
      return
    end
    if trackFlowState.mCompetitiveAwaitingAiSpawn then return end
    if M.spawnedTrackAiCount() == 0 then return end
  end

  M.tryCommitTrackGridStaging(playerVehicleId, { skipAiPrereq = true })
end

function M.onUpdateRacingTeamProxyParkingLoop()
  if not M.trackFlowState.racingTeamProxyRaceActive then return end
  if M.trackFlowState.sanctionedCareerGoToRaceActive then return end
  if not M.trackFlowState.inTrackFlowContext then return end
  local session = sess()
  if session.mActiveRace or session.staged or trackFlowState.mCompetitiveCountdownJobActive then return end

  if not proxyParkingRequestReady() then return end
  M.ensurePlayerStagingSpotLoaded()
  if not trackFlowState.mPlayerStagingSpot then return end

  local proxyBusinessId = M.trackFlowState.racingTeamProxyBusinessId
  local fleetVehicleId = M.trackFlowState.racingTeamProxyFleetVehicleId
  if not proxyBusinessId or not fleetVehicleId then return end

  if overhaul_events_utils.isPlayerInPursuit() then return end

  local businessFleet = overhaul_career_business_fleet
  if not businessFleet then return end

  local playerVehicle = be:getPlayerVehicle(0)
  if not playerVehicle then return end
  local playerVehicleId = playerVehicle:getID()

  local matchedBusinessId, matchedFleetVehicleId = businessFleet.getBusinessVehicleFromSpawnedId(playerVehicleId)
  local inTeamCar = matchedBusinessId and matchedFleetVehicleId and proxyVehicleIdEqual(matchedBusinessId, proxyBusinessId) and proxyVehicleIdEqual(matchedFleetVehicleId, fleetVehicleId)
  local rideAlong = overhaul_career_business_racingTeam_rideAlong
  if not inTeamCar then
    stageProxyTeleportOutsideTeamCar(businessFleet, proxyBusinessId, fleetVehicleId, playerVehicleId, rideAlong)
    return
  end
  commitProxyParkingTeamCar(playerVehicleId)
end

--- Racing team: stage at the selected circuit, enter the fleet car, then continue the grid/AI flow.
-- Business staging entry ----------------------------------------------------------------------------

local function proxyBusinessStartInputs(businessId)
  local businessRaceFlow = racingTeamRaceFlowMod()
  if not businessRaceFlow then
    M.exitRacingTeamProxyStagingLoadingScreen()
    return nil, nil, { ok = false, err = "no_proxy_flow" }
  end
  if not businessId then
    M.exitRacingTeamProxyStagingLoadingScreen()
    return nil, nil, { ok = false, err = "no_business" }
  end
  local proxyRaceRequest = businessRaceFlow.getProxyDriverRaceRequest(businessId)
  if not proxyRaceRequest or not proxyRaceRequest.racingTeamProxyRace then
    M.exitRacingTeamProxyStagingLoadingScreen()
    return nil, nil, { ok = false, err = "no_proxy_request" }
  end
  if M.trackFlowState.sanctionedCareerGoToRaceActive then
    M.exitRacingTeamProxyStagingLoadingScreen()
    return nil, nil, { ok = false, err = "sanctioned_phone_active" }
  end
  local session = sess()
  if session.mActiveRace or session.staged or trackFlowState.mCompetitiveCountdownJobActive then
    M.exitRacingTeamProxyStagingLoadingScreen()
    return nil, nil, { ok = false, err = "race_or_staging_active" }
  end
  if overhaul_events_utils.isPlayerInPursuit() then
    M.exitRacingTeamProxyStagingLoadingScreen()
    return nil, nil, { ok = false, err = "in_pursuit" }
  end

  return proxyRaceRequest, session, nil
end

local function initializeProxyBusinessStaging(businessId, proxyRaceRequest, session)
  -- Team loading overlay for remaining work: requestGameState, staging spot, teleport (matches spectate preflight).
  M.enterRacingTeamProxyStagingLoadingEarly()

  M.resetTrackGridFlowFlags()

  local proxyBusinessId = tonumber(businessId) or businessId
  local fleetVehicleId = tonumber(proxyRaceRequest.fleetVehicleId) or proxyRaceRequest.fleetVehicleId
  M.trackFlowState.racingTeamProxyRaceActive = true
  M.trackFlowState.racingTeamProxyBusinessId = proxyBusinessId
  M.trackFlowState.racingTeamProxyFleetVehicleId = fleetVehicleId
  local lapCount = tonumber(proxyRaceRequest.lapCount)
  if lapCount and lapCount > 0 then
    M.trackFlowState.sanctionedRaceLapCount = lapCount
  else
    M.trackFlowState.sanctionedRaceLapCount = nil
  end
  local raceRouteType = proxyRaceRequest.raceRouteType
  M.trackFlowState.useAltRoute = type(raceRouteType) == "string" and raceRouteType:lower() == "alt"
  syncRacingTeamProxyBracketFromRequest(proxyRaceRequest)

  M.trackFlowState.inTrackFlowContext = true
  session.saveGameState = true
  core_gamestate.requestGameState()
  core_jobsystem.create(function(job)
    job.sleep(0.1)
    refreshProxySpectatorUiIfMinimal()
    job.sleep(0.2)
    refreshProxySpectatorUiIfMinimal()
  end)

  return proxyBusinessId, fleetVehicleId
end

local function proxyBusinessStartFailure(reason)
  M.exitRacingTeamProxyStagingLoadingScreen()
  M.clearRacingTeamProxyParkingState()
  M.trackFlowState.inTrackFlowContext = false
  return { ok = false, err = reason }
end

local function enterProxyBusinessFleetCar(businessFleet, proxyBusinessId, fleetVehicleId)
  local rideAlong = overhaul_career_business_racingTeam_rideAlong
  if rideAlong and not rideAlong.hasPreRaceWorldState() then rideAlong.savePreRaceWorldState() end

  -- Finish teleporting before returning so the business UI releases its navigation lock at the right time.

  if not businessFleet.teleportSpawnedBusinessVehicleToSpot(proxyBusinessId, fleetVehicleId, trackFlowState.mPlayerStagingSpot) then
    return proxyBusinessStartFailure("teleport_failed")
  end

  local spawnedTeamVehicleId = businessFleet.getSpawnedVehicleId(proxyBusinessId, fleetVehicleId)
  local spawnedTeamVehicle = spawnedTeamVehicleId and be:getObjectByID(spawnedTeamVehicleId)
  if not spawnedTeamVehicle then
    return proxyBusinessStartFailure("enter_vehicle_failed")
  end
  pcall(function()
    be:enterVehicle(0, spawnedTeamVehicle)
  end)

  M.relayRacingTeamProxyOverlay({
    visible = true,
    businessId = proxyBusinessId and tostring(proxyBusinessId) or "",
    inRace = false,
    playerTeleportedToTeamCar = true,
  })
  refreshProxySpectatorUiIfMinimal()

  return nil
end

local function scheduleProxyBusinessStagingTail()
  -- Team loading stays up until tryCommitTrackGridStaging succeeds (grid staged + countdown started).
  trackFlowState.mRacingTeamProxyNextAttemptClock = nil
  core_jobsystem.create(function(job)
    pcall(function()
      racingTeamProxyRunStagingTailAfterPlayerInTeamCar(job)
    end)
    refreshProxySpectatorUiIfMinimal()
    trackFlowState.mRacingTeamProxyNextAttemptClock = nil
    M.onUpdateRacingTeamProxyParkingLoop()
  end)
end

function M.beginRacingTeamProxyRaceFromBusinessComputer(businessId)
  local proxyRaceRequest, session, refusal = proxyBusinessStartInputs(businessId)
  if refusal then return refusal end
  local ok, reason = M.setCompetitiveRace(proxyRaceRequest.raceName,
    string.lower(tostring(proxyRaceRequest.raceRouteType or "main")) == "alt")
  if not ok then return proxyBusinessStartFailure(reason) end
  local proxyBusinessId, fleetVehicleId = initializeProxyBusinessStaging(businessId, proxyRaceRequest, session)
  M.ensurePlayerStagingSpotLoaded()
  if not trackFlowState.mPlayerStagingSpot then return proxyBusinessStartFailure("no_staging_spot") end
  local businessFleet = overhaul_career_business_fleet
  if not businessFleet then return proxyBusinessStartFailure("no_inventory") end
  local entryFailure = enterProxyBusinessFleetCar(businessFleet, proxyBusinessId, fleetVehicleId)
  if entryFailure then return entryFailure end
  scheduleProxyBusinessStagingTail()
  return { ok = true }
end

-- Parking updates -----------------------------------------------------------------------------------

function M.onUpdateParkingResolve()
  if
    trackFlowState.mCompetitiveAwaitingAiSpawn
    and trackFlowState.mTrackGridAiSpawnWaitDeadline
    and os.time() >= trackFlowState.mTrackGridAiSpawnWaitDeadline
  then
    log("W", "competitiveTrackFlow", "AI spawn wait timed out; clearing await flag.")
    trackFlowState.mCompetitiveAwaitingAiSpawn = false
    trackFlowState.mTrackGridAiSpawnWaitDeadline = nil
    trackFlowState.mTrackGridParkingAiSpawnStarted = false
  end
end

function M.onUpdateParkingLoop()
  if
    not sess().mActiveRace
    and M.trackFlowState.inTrackFlowContext
    and M.trackFlowState.sanctionedCareerGoToRaceActive
    and not sess().staged
  then
    M.ensurePlayerStagingSpotLoaded()
    if not trackFlowState.mPlayerStagingSpot then return end
    local pv = be:getPlayerVehicle(0)
    local nowInParking = (
      pv
      and trackFlowState.mPlayerStagingSpot
      and isPlayerInTrackParkingCommitSpot(trackFlowState.mPlayerStagingSpot)
    ) or false
    if not nowInParking then
      if trackFlowState.mSanctionedParkingUiPhase ~= "hidden" then M.sanctionedParkingAbortStaging() end
      return
    end
    if trackFlowState.mSanctionedParkingUiPhase == "hidden" then trackFlowState.mSanctionedParkingUiPhase = "prompt" end
    local clk = (os and os.clock) and os.clock() or 0
    if
      not trackFlowState.mSanctionedParkingLiveRefreshClock
      or (clk - trackFlowState.mSanctionedParkingLiveRefreshClock) >= SANCTIONED_PARKING_LIVE_HP_REFRESH_INTERVAL
    then
      trackFlowState.mSanctionedParkingLiveRefreshClock = clk
      local ar = overhaul_events_aiRacers
      if ar then ar.requestStagingUiLivePowerRefresh() end
    end
    if
      not trackFlowState.mSanctionedParkingUiPushClock
      or (clk - trackFlowState.mSanctionedParkingUiPushClock) >= SANCTIONED_PARKING_UI_PUSH_INTERVAL
    then
      trackFlowState.mSanctionedParkingUiPushClock = clk
      pushSanctionedParkingGui()
    end
  end
end

-- Path preload and grid state -----------------------------------------------------------------------

function M.preloadAiPathsForTrack()
  local aiRacers = overhaul_events_aiRacers
  if not aiRacers then return end
  local levelId = getCurrentLevelIdentifier()
  local races = sess().races
  if not levelId then return end
  M.getCompetitiveRaceDefinition(nil)
  for id, definition in pairs(trackFlowState.definitions or {}) do
    if definition.competitive then
      local race = races and races[id] or definition.race
      race._competitiveRaceId, race._competitiveRouteType = id, "main"
      aiRacers.preloadPathForRace(race)
      if race.altRoute and race.altRoute.checkpointRoad then
        race.altRoute._competitiveRaceId, race.altRoute._competitiveRouteType = id, "alt"
        aiRacers.preloadPathForRace(race.altRoute)
      end
    end
  end
end

function M.getCompetitiveAwaitingAiSpawn()
  return trackFlowState.mCompetitiveAwaitingAiSpawn
end

function M.getCompetitiveCountdownJobActive()
  return trackFlowState.mCompetitiveCountdownJobActive
end

function M.getTrackGridParkingAiSpawnStarted()
  return trackFlowState.mTrackGridParkingAiSpawnStarted
end

function M.setTrackGridParkingAiSpawnStarted(v)
  trackFlowState.mTrackGridParkingAiSpawnStarted = v
end

-- Lifecycle -----------------------------------------------------------------------------------------

local function onExtensionLoaded() end

-- Public API --------------------------------------------------------------------------------------

M.onExtensionLoaded = onExtensionLoaded

return M
