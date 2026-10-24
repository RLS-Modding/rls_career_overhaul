-- Racing team proxy races: stores the armed driver request per business and starts the proxy race through the track flow.
-- Read map: proxy request storage, request phases, simulated start, public API.
local M = {}

M.dependencies = { 'overhaul_events_competitiveTrackFlow' }

local proxyDriverRaceRequestByBusiness = {}

local function normalizeBusinessId(value)
  return tonumber(value) or value
end

local function cloneRequest(req)
  if not req or type(req) ~= "table" then
    return nil
  end
  local copy = {}
  for k, v in pairs(req) do
    copy[k] = v
  end
  return copy
end

local function getRacingTeamModule()
  return overhaul_career_business_racingTeam_racingTeam
end

local function getTrackFlowModule()
  return overhaul_events_competitiveTrackFlow
end

local function invalidResponse(err)
  return { ok = false, err = err or "lua_error" }
end

local function setProxyDriverRaceRequest(businessId, req)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return nil
  end
  local id = tostring(businessId)
  if req and type(req) == "table" then
    proxyDriverRaceRequestByBusiness[id] = cloneRequest(req)
  else
    proxyDriverRaceRequestByBusiness[id] = nil
  end
  return proxyDriverRaceRequestByBusiness[id]
end

local function getProxyDriverRaceRequest(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return nil
  end
  local id = tostring(businessId)
  return cloneRequest(proxyDriverRaceRequestByBusiness[id])
end

local function clearProxyRequestStorage(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return nil
  end
  local id = tostring(businessId)
  proxyDriverRaceRequestByBusiness[id] = nil
end

local function loadPersistedProxyDriverRaceRequest(businessId, persistedRequest)
  if type(persistedRequest) == "table" then
    return setProxyDriverRaceRequest(businessId, persistedRequest)
  end
  return setProxyDriverRaceRequest(businessId, nil)
end

local function getPersistedProxyDriverRaceRequestForSave(businessId)
  return getProxyDriverRaceRequest(businessId)
end

local function onCareerActivated()
  proxyDriverRaceRequestByBusiness = {}
end

local function beginRacingTeamProxyRaceFromBusinessComputer(businessId)
  local trackFlow = getTrackFlowModule()
  if not trackFlow or not trackFlow.beginRacingTeamProxyRaceFromBusinessComputer then
    return invalidResponse("no_track_flow")
  end
  return trackFlow.beginRacingTeamProxyRaceFromBusinessComputer(businessId)
end

local function notifyProxyRaceRequested(opts)
  extensions.hook("onOverhaulRacingTeamProxyRaceRequested", opts)
end

-- Keeps the player's car and walking state for the restore after the race.
local function saveRideAlongWorldState()
  local rideAlong = overhaul_career_business_racingTeam_rideAlong
  if rideAlong then
    if not (rideAlong.hasPreRaceWorldState and rideAlong.hasPreRaceWorldState()) then
      rideAlong.savePreRaceWorldState()
    end
  end
end

-- Shows the staging overlay through the track flow, or straight to the UI when the flow is not loaded.
local function showProxyOverlay(request, spectateStaging)
  local overlay = {
    visible = true,
    businessId = request and request.businessId,
    inRace = false,
    spectateStaging = spectateStaging,
  }
  local trackFlow = getTrackFlowModule()
  if trackFlow and trackFlow.relayRacingTeamProxyOverlay then
    trackFlow.relayRacingTeamProxyOverlay(overlay)
  else
    guihooks.trigger("racingTeamProxyOverlay", overlay)
  end
end

function M.requestProxyDriverRace(opts)
  if type(opts) ~= "table" then
    return { ok = false, err = "invalid_opts" }
  end
  local racingTeamModule = getRacingTeamModule()
  if not racingTeamModule or not racingTeamModule.proxyDriverRaceValidateAndBuildRequest then
    return { ok = false, err = "no_racing_team" }
  end
  local pack = racingTeamModule.proxyDriverRaceValidateAndBuildRequest(opts)
  if not pack or pack.ok ~= true then
    return pack or { ok = false, err = "validate_failed" }
  end
  setProxyDriverRaceRequest(pack.businessId, pack.request)
  if racingTeamModule.persistRacingTeamBusinessJson then
    racingTeamModule.persistRacingTeamBusinessJson(pack.businessId)
  end
  saveRideAlongWorldState()
  showProxyOverlay(pack.request, opts and opts.spectateStaging == true)
  if pack.request then
    notifyProxyRaceRequested(pack.request)
  end
  return { ok = true }
end

-- Leaves the staging loading screen when a proxy race cannot start.
local function exitStagingLoadingScreen(trackFlow)
  if trackFlow and trackFlow.exitRacingTeamProxyStagingLoadingScreen then
    trackFlow.exitRacingTeamProxyStagingLoadingScreen()
  end
end

-- Arms a proxy race in spectate staging, then starts it from the business computer.
function M.simulateRacingTeamProxyRace(opts)
  if type(opts) ~= "table" then
    return invalidResponse("invalid_opts")
  end
  local trackFlow = getTrackFlowModule()
  local armOpts = {}
  for k, v in pairs(opts) do
    armOpts[k] = v
  end
  armOpts.spectateStaging = true
  local armRes = M.requestProxyDriverRace(armOpts)
  if not armRes or armRes.ok ~= true then
    exitStagingLoadingScreen(trackFlow)
    return armRes or invalidResponse("request_failed")
  end
  local businessId = normalizeBusinessId(opts.businessId)
  if not businessId then
    exitStagingLoadingScreen(trackFlow)
    return invalidResponse("missing_business_or_driver")
  end
  local beginRes = beginRacingTeamProxyRaceFromBusinessComputer(businessId)
  if not beginRes or beginRes.ok ~= true then
    exitStagingLoadingScreen(trackFlow)
  end
  if type(beginRes) ~= "table" then
    return invalidResponse("begin_failed")
  end
  return beginRes
end

function M.clearProxyDriverRaceRequest(businessId)
  clearProxyRequestStorage(businessId)
  local racingTeamModule = getRacingTeamModule()
  if racingTeamModule then
    racingTeamModule.persistRacingTeamBusinessJson(businessId)
  end
end

function M.getProxyDriverAiDifficultyBlendT(businessId, driverId)
  local racingTeamModule = getRacingTeamModule()
  if racingTeamModule then
    return racingTeamModule.getProxyDriverAiDifficultyBlendT(businessId, driverId)
  end
  return 1
end

local function findProxyDriverRaceRequestForLevel(levelId)
  if type(levelId) ~= "string" or levelId == "" then
    return nil, nil
  end
  local manager = overhaul_career_business_manager
  local purchased = manager.getPurchasedBusinesses("racingTeam")
  if not purchased then
    return nil, nil
  end
  for bid, _ in pairs(purchased) do
    local req = getProxyDriverRaceRequest(bid)
    if req and req.racingTeamProxyRace and req.levelId == levelId then
      return req, bid
    end
  end
  return nil, nil
end

M.loadPersistedProxyDriverRaceRequest = loadPersistedProxyDriverRaceRequest
M.getPersistedProxyDriverRaceRequestForSave = getPersistedProxyDriverRaceRequestForSave
M.setProxyDriverRaceRequest = setProxyDriverRaceRequest
M.getProxyDriverRaceRequest = getProxyDriverRaceRequest
M.findProxyDriverRaceRequestForLevel = findProxyDriverRaceRequestForLevel
M.onCareerActivated = onCareerActivated
M.beginRacingTeamProxyRaceFromBusinessComputer = beginRacingTeamProxyRaceFromBusinessComputer

return M
