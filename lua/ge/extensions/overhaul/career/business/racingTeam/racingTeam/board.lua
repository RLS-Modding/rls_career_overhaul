-- Racing team board: tabs, sim clock, cooldowns, level info, offer board, valuation, drivers, league invites, sponsors and matching.
-- Read map: config, tabs, sim clock, level info, limits, drivers and their save file, offer matching, runtime hooks, API, part.new.
local businessSaveState = require("overhaul/lib/business/saveState")
local part = {}
local levelData = require("overhaul/lib/world/levelData")
local devLog = require('overhaul/career/business/racingTeam/racingTeam/devLog')

-- Config ------------------------------------------------------------------------------------------

local LEAGUE_INVITE_DEFAULTS_BY_TARGET = {
  [2] = { orgName = "Amateur Racing Association", acronym = "ARA", feeEarly = 1500, feeLate = 2500, feeEscalateMinutes = 60 },
  [3] = { orgName = "National Racing Council", acronym = "NRC", feeEarly = 2500, feeLate = 3500, feeEscalateMinutes = 60 },
  [4] = { orgName = "Professional Motorsports Alliance", acronym = "PMA", feeEarly = 3500, feeLate = 4500, feeEscalateMinutes = 60 },
}

-- Tabs --------------------------------------------------------------------------------------------

local function baseTabDefinitions()
  return {
    { id = "home", label = "Home", component = "BusinessHomeView", section = "BASIC", order = 1,
      icon = '<path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/>' },
    { id = "jobs", label = "Goals", component = "BusinessJobsTab", section = "BASIC", order = 2,
      icon = '<path d="M9 11l3 3L22 4M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/>' },
    { id = "vehicles", label = "Vehicles", component = "BusinessVehiclesTab", section = "BASIC", order = 3,
      icon = '<path d="M19 17h2c.6 0 1-.4 1-1v-3c0-.9-.7-1.7-1.5-1.9C18.7 10.6 16 10 16 10s-1.3-1.4-2.2-2.3c-.5-.4-1.1-.7-1.8-.7H5c-.6 0-1.1.4-1.4.9l-1.4 2.9A3.7 3.7 0 0 0 2 12v4c0 .6.4 1 1 1h2"/><circle cx="7" cy="17" r="2"/><path d="M9 17h6"/><circle cx="17" cy="17" r="2"/>' },
    { id = "inventory", label = "Inventory", component = "BusinessInventoryTab", section = "BASIC", order = 3.5,
      icon = '<path d="M16.5 9.4l-9-5.19M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><polyline points="3.27 6.96 12 12.01 20.73 6.96"/><line x1="12" y1="22.08" x2="12" y2="12"/>' },
    { id = "race", label = "Race", component = "BusinessRacingTab", section = "BASIC", order = 4,
      icon = '<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>' },
    { id = "drivers", label = "Drivers", component = "BusinessDriversTab", section = "BASIC", order = 5,
      icon = '<circle cx="12" cy="7" r="4"/><path d="M6 21v-2a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v2"/><circle cx="19" cy="7" r="3"/><path d="M22 21v-2a3 3 0 0 0-3-3h-2"/>' },
    { id = "finances", label = "Finances", component = "BusinessFinancesTab", section = "BASIC", order = 6,
      icon = '<path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/>' },
  }
end

local function devConsoleTab()
  return {
    id = "dev-console", label = "Dev Console", component = "BusinessRacingTeamDevConsoleTab", section = "BASIC", order = 200,
    icon = '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M8 12h8M12 8v8"/>',
  }
end

local function ensureTabsRegistered(businessType)
  for _, tab in ipairs(baseTabDefinitions()) do
    overhaul_career_business_tabRegistry.registerTab(businessType, tab)
  end
  if devLog.consoleEnabled() then
    overhaul_career_business_tabRegistry.registerTab(businessType, devConsoleTab())
  else
    overhaul_career_business_tabRegistry.unregisterTab(businessType, "dev-console")
  end
  return true
end

-- Sim clock ---------------------------------------------------------------------------------------


-- The contract clock is in sim minutes.
local function getCareerSimTime()
  if overhaul_events_fre_state and overhaul_events_fre_state.getState then
    local state = overhaul_events_fre_state.getState()
    local t = tonumber(state and state.simTime)
    if t then
      return t
    end
  end
  return os.time() / 60
end

local function getCareerSimTimeSeconds()
  return getCareerSimTime() * 60
end

-- Level info --------------------------------------------------------------------------------------

local function getRacingTeamLevelId()
  if overhaul_events_fre_state and overhaul_events_fre_state.getCurrentLevelId then
    local lid = overhaul_events_fre_state.getCurrentLevelId()
    if type(lid) == "string" and lid ~= "" then
      return lid
    end
  end
  local g = getCurrentLevelIdentifier()
  if type(g) == "string" and g ~= "" then
    return g
  end
  return ""
end

local function resolveRacingTeamLeaderboardLevelIds()
  local out = {}
  local seen = {}
  local _, maps = levelData.loadMaps()
  for _, map in ipairs(maps) do
    local path = levelData.assetPath(map.id, map.racingTeamInfoFile or "racingTeam_info.json")
    if map.careerCompatible and FS:fileExists(path) then
      seen[map.id] = true
      table.insert(out, map.id)
    end
  end
  local cur = getRacingTeamLevelId()
  if type(cur) == "string" and cur ~= "" and not seen[cur]
    and FS:fileExists(levelData.assetPath(cur, (levelData.getMap(cur) or {}).racingTeamInfoFile or "racingTeam_info.json")) then
    seen[cur] = true
    table.insert(out, cur)
  end
  return out
end

local function shallowCopyTable(t)
  local o = {}
  if type(t) == "table" then
    for k, v in pairs(t) do
      o[k] = v
    end
  end
  return o
end

-- Level info files to read, in order: the level's own alias first, then the two generic names.
local function getRacingTeamLevelInfoJsonCandidates(lid)
  local list = {}
  if type(lid) ~= "string" or lid == "" then
    return list
  end
  local map = levelData.getMap(lid)
  if map and map.racingTeamInfoFile then
    table.insert(list, levelData.assetPath(lid, map.racingTeamInfoFile))
  end
  table.insert(list, levelData.assetPath(lid, "racingTeam_info.json"))
  return list
end

local function loadRacingTeamLevelInfoJsonRaw(lid)
  for _, path in ipairs(getRacingTeamLevelInfoJsonCandidates(lid)) do
    if FS:fileExists(path) then
      local data = jsonReadFile(path)
      if data and type(data) == "table" then
        return data
      end
    end
  end
  log("W", "racingTeam", "No local racing team info on " .. tostring(lid))
  return nil
end

-- Fills a text field only when the level file left it blank.
local function fillIfBlank(levelText, key, value)
  if not levelText[key] or levelText[key] == "" then
    levelText[key] = value
  end
end

local function fillDefaultLeagueText(levelText, n)
  local ac = levelText[string.format("league%dInviteAcronym", n)]
  fillIfBlank(levelText, string.format("splashLeague%dTitle", n), ac .. " invitation")
  local bodyKey = string.format("splashLeague%dBody", n)
  if n == 2 then
    fillIfBlank(levelText, bodyKey,
      "Tier one is complete. You can register with " .. ac .. " now (fee from your business account) or choose Later and decide from the Goals tab.")
  else
    fillIfBlank(levelText, bodyKey, string.format(
      "Your league %d objectives are complete. Register with %s to advance into a higher league — tougher cars, tighter fields, bigger stakes. Fee posts to your team account when you accept, or choose Later and decide from the Goals tab.",
      n - 1, ac))
  end
  fillIfBlank(levelText, string.format("splashLeague%dAcceptLabel", n), "Accept")
  fillIfBlank(levelText, string.format("splashLeague%dLaterLabel", n), "Later")
  fillIfBlank(levelText, string.format("splashLeague%dWelcomeTitle", n), "You're in")
  local welBodyKey = string.format("splashLeague%dWelcomeBody", n)
  if n == 2 then
    fillIfBlank(levelText, welBodyKey,
      "Registration fee posted to your team account. Welcome to the regional grid — hire drivers, keep the cars healthy, and use the Race tab when you are ready to run.")
  else
    fillIfBlank(levelText, welBodyKey, string.format(
      "Registration fee posted. You are now competing in %s — keep the operation tight, hire drivers who can hold position, and use the Race tab when you are ready to run.",
      ac))
  end
  fillIfBlank(levelText, string.format("splashLeague%dWelcomeContinueLabel", n), "Let's Go!")
  fillIfBlank(levelText, string.format("msgWelcomeLeague%d", n), "Welcome to " .. ac .. " — hire drivers and run sanctioned races.")
end

-- Preserve level-specific league names when filling omitted UI text.
local function applyRacingTeamLevelTextDefaults(levelText)
  local ac2 = levelText.league2InviteAcronym
  fillIfBlank(levelText, "sponsorFocusLabel", ac2 .. " team racing")
  fillIfBlank(levelText, "msgRaceOffersLeague2",
    ac2 .. " management: assign proxy races from the Drivers tab (rolled events — no job board).")
  fillIfBlank(levelText, "msgWelcomeToastTitle", ac2)
  fillIfBlank(levelText, "msgProxyRaceScheduledToastTitle", ac2)
  fillIfBlank(levelText, "msgNoSanctionedRaces",
    "No sanctioned race offers yet. Keep working through your team goals — circuit offers unlock as you progress.")
  fillIfBlank(levelText, "splashPurchaseTitle", "Welcome")
  fillIfBlank(levelText, "splashPurchaseBody",
    "You own the racing team. Open the business computer and work through goals to grow the program.")
  fillIfBlank(levelText, "splashPurchaseContinueLabel", "Continue")
  fillIfBlank(levelText, "splashCareerFinaleTitle", "Well done indeed")
  fillIfBlank(levelText, "splashCareerFinaleBody",
    "Look how far you've come..... what started as a few bucks and a dream has turned into a career. You know what they say, \"find something you love to do and you'll never work a day in your life\"\n\n"
      .. "How does it feel? National recognition, dreams realized? You've made it. Enjoy this career you've built - keep pushing the envelope and competing - it doesn't get any easier, but, you know that by now.\n\n"
      .. "Congratulations kid, well done indeed")
  fillIfBlank(levelText, "splashCareerFinaleContinueLabel", "Continue")
  for n = 2, 4 do
    fillDefaultLeagueText(levelText, n)
  end
end

local function setIfString(o, key, val)
  if type(val) == "string" and val ~= "" then
    o[key] = val
  end
end

-- Every level text key starts as its built-in default; nil keys are filled later from the level file or defaults.
local function emptyLevelText()
  local levelText = {
    leagueDisplayNames = {},
    extra = {},
  }
  for n = 2, 4 do
    local inviteDefaults = LEAGUE_INVITE_DEFAULTS_BY_TARGET[n]
    levelText[string.format("league%dInviteOrgName", n)] = inviteDefaults.orgName
    levelText[string.format("league%dInviteAcronym", n)] = inviteDefaults.acronym
    levelText[string.format("league%dInviteFeeEarly", n)] = inviteDefaults.feeEarly
    levelText[string.format("league%dInviteFeeLate", n)] = inviteDefaults.feeLate
    levelText[string.format("league%dInviteFeeEscalateMinutes", n)] = inviteDefaults.feeEscalateMinutes
    levelText[string.format("league%dBankReasonShort", n)] = nil
    levelText[string.format("splashLeague%dTitle", n)] = nil
    levelText[string.format("splashLeague%dBody", n)] = nil
    levelText[string.format("splashLeague%dAcceptLabel", n)] = nil
    levelText[string.format("splashLeague%dLaterLabel", n)] = nil
    levelText[string.format("splashLeague%dImageUrl", n)] = nil
    levelText[string.format("splashLeague%dWelcomeTitle", n)] = nil
    levelText[string.format("splashLeague%dWelcomeBody", n)] = nil
    levelText[string.format("splashLeague%dWelcomeContinueLabel", n)] = nil
    levelText[string.format("splashLeague%dWelcomeImageUrl", n)] = nil
    levelText[string.format("msgWelcomeLeague%d", n)] = nil
  end
  return levelText
end

local function applyRawLeagueInvites(levelText, raw)
  for n = 2, 4 do
    local inv = raw[string.format("league%dInvite", n)]
    if type(inv) == "table" then
      setIfString(levelText, string.format("league%dInviteOrgName", n), inv.orgName)
      setIfString(levelText, string.format("league%dInviteAcronym", n), inv.acronym)
      local fe = tonumber(inv.feeEarly)
      if fe and fe > 0 then levelText[string.format("league%dInviteFeeEarly", n)] = math.floor(fe) end
      local fl = tonumber(inv.feeLate)
      if fl and fl > 0 then levelText[string.format("league%dInviteFeeLate", n)] = math.floor(fl) end
      local em = tonumber(inv.feeEscalateMinutes)
      if em and em > 0 then levelText[string.format("league%dInviteFeeEscalateMinutes", n)] = math.floor(em) end
      setIfString(levelText, string.format("league%dBankReasonShort", n), inv.bankReasonShort)
    end
  end
end

local function applyRawMessages(levelText, raw)
  local msg = raw.messages
  if type(msg) == "table" then
    setIfString(levelText, "msgWelcomeLeague2", msg.welcomeLeague2)
    setIfString(levelText, "msgWelcomeLeague3", msg.welcomeLeague3)
    setIfString(levelText, "msgWelcomeLeague4", msg.welcomeLeague4)
    setIfString(levelText, "msgWelcomeToastTitle", msg.welcomeToastTitle)
    setIfString(levelText, "msgRaceOffersLeague2", msg.raceOffersLeague2)
    setIfString(levelText, "msgProxyRaceScheduledToastTitle", msg.proxyRaceScheduledToastTitle)
  end
  local hints = raw.hints
  if type(hints) == "table" and type(hints.noSanctionedRaces) == "string" and hints.noSanctionedRaces ~= "" then
    levelText.msgNoSanctionedRaces = hints.noSanctionedRaces
  end
end

local function applyRawSplashes(levelText, splashes)
  local purchaseSplash = splashes.purchase
  if type(purchaseSplash) == "table" then
    setIfString(levelText, "splashPurchaseTitle", purchaseSplash.title)
    setIfString(levelText, "splashPurchaseBody", purchaseSplash.body)
    setIfString(levelText, "splashPurchaseContinueLabel", purchaseSplash.continueLabel)
    setIfString(levelText, "splashPurchaseImageUrl", purchaseSplash.imageUrl)
  end
  local careerFinaleSplash = splashes.careerFinale
  if type(careerFinaleSplash) == "table" then
    setIfString(levelText, "splashCareerFinaleTitle", careerFinaleSplash.title)
    setIfString(levelText, "splashCareerFinaleBody", careerFinaleSplash.body)
    setIfString(levelText, "splashCareerFinaleContinueLabel", careerFinaleSplash.continueLabel)
    setIfString(levelText, "splashCareerFinaleImageUrl", careerFinaleSplash.imageUrl)
  end
  for n = 2, 4 do
    local leagueSplash = splashes[string.format("league%d", n)]
    if type(leagueSplash) == "table" then
      setIfString(levelText, string.format("splashLeague%dTitle", n), leagueSplash.title)
      setIfString(levelText, string.format("splashLeague%dBody", n), leagueSplash.body)
      setIfString(levelText, string.format("splashLeague%dAcceptLabel", n), leagueSplash.acceptLabel)
      setIfString(levelText, string.format("splashLeague%dLaterLabel", n), leagueSplash.laterLabel)
      setIfString(levelText, string.format("splashLeague%dImageUrl", n), leagueSplash.imageUrl)
    end
    local leagueWelcomeSplash = splashes[string.format("league%dWelcome", n)]
    if type(leagueWelcomeSplash) == "table" then
      setIfString(levelText, string.format("splashLeague%dWelcomeTitle", n), leagueWelcomeSplash.title)
      setIfString(levelText, string.format("splashLeague%dWelcomeBody", n), leagueWelcomeSplash.body)
      setIfString(levelText, string.format("splashLeague%dWelcomeContinueLabel", n), leagueWelcomeSplash.continueLabel)
      setIfString(levelText, string.format("splashLeague%dWelcomeImageUrl", n), leagueWelcomeSplash.imageUrl)
    end
  end
end

local function applyRawLevelFields(levelText, raw)
  applyRawLeagueInvites(levelText, raw)
  local sp = raw.sponsorOffer
  if type(sp) == "table" and type(sp.focusLabel) == "string" and sp.focusLabel ~= "" then
    levelText.sponsorFocusLabel = sp.focusLabel
  end
  applyRawMessages(levelText, raw)
  if type(raw.leagueDisplayNames) == "table" then
    levelText.leagueDisplayNames = shallowCopyTable(raw.leagueDisplayNames)
  end
  if type(raw.extra) == "table" then
    levelText.extra = shallowCopyTable(raw.extra)
  end
  if type(raw.splashes) == "table" then
    applyRawSplashes(levelText, raw.splashes)
  end
end

local function normalizeRacingTeamLevelInfo(raw)
  local levelText = emptyLevelText()
  if type(raw) == "table" then
    applyRawLevelFields(levelText, raw)
  end
  applyRacingTeamLevelTextDefaults(levelText)
  return levelText
end

local function getRacingTeamLevelInfo(rtState, levelId)
  local lid = ""
  if type(levelId) == "string" then
    lid = levelId
  end
  local cached = rtState.rtInternal.racingTeamLevelInfoNormalizedCache[lid]
  if cached then
    return cached
  end
  local raw = nil
  if lid ~= "" then
    raw = loadRacingTeamLevelInfoJsonRaw(lid)
  end
  local normalized = normalizeRacingTeamLevelInfo(raw)
  rtState.rtInternal.racingTeamLevelInfoNormalizedCache[lid] = normalized
  return normalized
end

-- Cooldowns and limits ----------------------------------------------------------------------------

local function getMaxPulledOutVehicles(rtState, parts, businessId)
  local cap = rtState.K.RACING_TEAM_GARAGE_PARKING_CAP or 4
  local slotLv = parts.helpers.getRacingTeamGarageSlotsSkillLevel(businessId)
  local function clampPulls(n)
    return math.min(cap, math.max(1, math.floor(tonumber(n) or 1)))
  end
  if rtState.rtInternal.getCurrentLeague(businessId) == "league1" then
    local base = rtState.rtInternal.allTierOneGoalsComplete(businessId) and 2 or 1
    return clampPulls(base + slotLv)
  end
  local n = math.max(2, rtState.K.MAX_LEAGUE2_PULLED_OUT) + slotLv
  return clampPulls(n)
end

local function getMaxActiveJobs(rtState, parts, businessId)
  local cap = rtState.K.RACING_TEAM_GARAGE_PARKING_CAP or 4
  local n = 2 + parts.helpers.getRacingTeamGarageSlotsSkillLevel(businessId)
  return math.min(cap, math.max(1, n))
end

local function getCurrentLeague(rtState, parts, businessId)
  local id = tostring(parts.helpers.normalizeBusinessId(businessId))
  parts.helpers.getOfferState(businessId)
  local v = rtState.currentLeagueByBusiness[id]
  if type(v) == "string" and v ~= "" then
    return v
  end
  return "league1"
end

local function leagueRankFromId(leagueId)
  local n = tonumber(string.match(tostring(leagueId or ""), "^league(%d+)$"))
  return n or 0
end

local function isLeagueAtLeast(leagueId, minRank)
  return leagueRankFromId(leagueId) >= (tonumber(minRank) or 2)
end

-- Reads the league through rtInternal so an override of the hook is honoured, as the callers always did.
local function isCurrentLeagueAtLeast(rtState, businessId, minRank)
  return rtState.rtInternal.isLeagueAtLeast(rtState.rtInternal.getCurrentLeague(businessId), minRank)
end

local function jobIdsMatch(sentJobId, offerJobId)
  local a = tonumber(sentJobId) or sentJobId
  local b = tonumber(offerJobId) or offerJobId
  return a == b
end

-- Drivers and their save file ---------------------------------------------------------------------

local function getRacingTeamDriverCapacity(rtState, parts, businessId)
  if rtState.rtInternal.getCurrentLeague(businessId) == "league1" then
    return 0
  end
  return 1 + parts.helpers.getSkillTreeNodeLevel(businessId, "driver", "expanded-roster")
end

local function getRacingTeamDriversSavePath(businessId, currentSavePath)
  if not currentSavePath or not businessId then
    return nil
  end
  return businessSaveState.businessFilePath(businessId, "racingDrivers.json", currentSavePath .. "")
end

local function writeRacingTeamDrivers(rtState, parts, businessId, currentSavePath, writer)
  businessId = parts.helpers.normalizeBusinessId(businessId)
  if not businessId or not rtState.businessDrivers[businessId] or not currentSavePath then
    return
  end
  local filePath = getRacingTeamDriversSavePath(businessId, currentSavePath)
  if not filePath then
    return
  end
  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not writer.exists(dirPath) then
    writer.mkdir(dirPath)
  end
  overhaul_career_saveSystem.jsonWriteFileSafe(filePath, { techs = rtState.businessDrivers[businessId] }, true)
end

-- The driver file is written by writeRacingTeamDrivers when the team saves, so this has nothing to do here.
local function saveRacingTeamDrivers(businessId, currentSavePath)
end

local function ensureRacingDriverIdentity(tech, index)
  if not tech.id then
    tech.id = index
  end
  if not tech.name or tech.name == "" then
    tech.name = string.format("Driver #%d", tonumber(tech.id) or index or 1)
  end
  tech.fired = tech.fired or false
  tech.currentAction = tech.currentAction or "idle"
  tech.state = tech.state or 0
  tech.stateElapsed = tech.stateElapsed or 0
  tech.stateDuration = tech.stateDuration or 0
  tech.racingSkillXp = math.max(0, math.floor(tonumber(tech.racingSkillXp) or 0))
  tech.sanctionedRacesFinished = math.max(0, math.floor(tonumber(tech.sanctionedRacesFinished) or 0))
  tech.sanctionedRaceWins = math.max(0, math.floor(tonumber(tech.sanctionedRaceWins) or 0))
  tech.sanctionedPodiums = math.max(0, math.floor(tonumber(tech.sanctionedPodiums) or 0))
end

local function highestDriverId(techs)
  local maxId = 0
  for _, tech in ipairs(techs) do
    if tech.id and tech.id > maxId then
      maxId = tech.id
    end
  end
  return maxId
end

local function ensureRacingTeamDriverSlots(rtState, parts, businessId)
  businessId = parts.helpers.normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local capacity = math.max(0, getRacingTeamDriverCapacity(rtState, parts, businessId))
  local techs = rtState.businessDrivers[businessId] or {}
  for _, tech in ipairs(techs) do
    ensureRacingDriverIdentity(tech, tech.id)
  end
  local nextId = highestDriverId(techs) + 1
  while #techs < capacity do
    local newTech = {
      id = nextId,
      name = string.format("Driver #%d", nextId),
      fired = true,
      currentAction = "idle",
      state = 0,
      stateElapsed = 0,
      stateDuration = 0,
      jobId = nil,
    }
    ensureRacingDriverIdentity(newTech, nextId)
    table.insert(techs, newTech)
    nextId = nextId + 1
  end
  rtState.businessDrivers[businessId] = techs
end

-- A driver's pending race offer keeps a wall-clock deadline, so a restored save resumes the countdown.
local function ensurePendingOfferWallDeadlineForTech(tech)
  local pr = tech and tech.pendingRaceOffer
  if not pr or type(pr) ~= "table" then
    return
  end
  local simDue = tonumber(pr.scheduledRaceSimTime)
  if not simDue then
    return
  end
  if tonumber(pr.scheduledRaceReadyWallEpoch) then
    return
  end
  local rem = math.max(0, math.ceil(simDue - getCareerSimTimeSeconds()))
  pr.scheduledRaceReadyWallEpoch = os.time() + rem
end

local function ensurePostRaceCooldownWallDeadlineForTech(tech)
  if not tech or type(tech) ~= "table" then
    return
  end
  local untilSim = tonumber(tech.racingCooldownUntilSimTime)
  if not untilSim then
    tech.postRaceCooldownReadyWallEpoch = nil
    return
  end
  local wallEpoch = tonumber(tech.postRaceCooldownReadyWallEpoch)
  if wallEpoch and wallEpoch > 0 and os.time() >= wallEpoch then
    tech.racingCooldownUntilSimTime = nil
    tech.postRaceCooldownReadyWallEpoch = nil
    return
  end
  local nowSim = getCareerSimTimeSeconds()
  if nowSim >= untilSim then
    tech.racingCooldownUntilSimTime = nil
    tech.postRaceCooldownReadyWallEpoch = nil
    return
  end
  if wallEpoch and wallEpoch > 0 then
    return
  end
  local remSim = math.max(0, math.ceil(untilSim - nowSim))
  tech.postRaceCooldownReadyWallEpoch = os.time() + remSim
end

local function readRacingTeamDriversFromSave(businessId)
  local techs = {}
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if not savePath then
    return techs
  end
  local filePath = getRacingTeamDriversSavePath(businessId, savePath)
  if not filePath or not FS:fileExists(filePath) then
    return techs
  end
  local data = jsonReadFile(filePath)
  if data and type(data) == "table" and type(data.techs) == "table" then
    for index, tech in ipairs(data.techs) do
      ensureRacingDriverIdentity(tech, tech.id or index)
      ensurePendingOfferWallDeadlineForTech(tech)
      ensurePostRaceCooldownWallDeadlineForTech(tech)
      table.insert(techs, tech)
    end
  end
  return techs
end

local function loadRacingTeamDrivers(rtState, parts, businessId)
  businessId = parts.helpers.normalizeBusinessId(businessId)
  if not businessId then
    return {}
  end
  if rtState.businessDrivers[businessId] then
    ensureRacingTeamDriverSlots(rtState, parts, businessId)
    for _, tech in ipairs(rtState.businessDrivers[businessId]) do
      ensurePendingOfferWallDeadlineForTech(tech)
      ensurePostRaceCooldownWallDeadlineForTech(tech)
    end
    return rtState.businessDrivers[businessId]
  end
  rtState.businessDrivers[businessId] = readRacingTeamDriversFromSave(businessId)
  ensureRacingTeamDriverSlots(rtState, parts, businessId)
  return rtState.businessDrivers[businessId]
end

local function getRacingTeamDriversRawForUI(rtState, parts, businessId)
  if getRacingTeamDriverCapacity(rtState, parts, businessId) < 1 then
    return {}
  end
  return rtState.loadRacingTeamDrivers(businessId)
end

local function getRacingTeamDriverById(rtState, businessId, techId)
  techId = tonumber(techId)
  if not techId then
    return nil
  end
  for _, tech in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
    if tonumber(tech.id) == techId then
      return tech
    end
  end
  return nil
end

local function getRacingTeamActiveJobByJobId(parts, businessId, jobId)
  local state = parts.helpers.getOfferState(businessId)
  for _, job in ipairs(state.active or {}) do
    if jobIdsMatch(jobId, job.jobId) then
      return job
    end
  end
  return nil
end

local function getBusinessVehicleRawByInventoryId(businessId, vehicleId)
  if not vehicleId then
    return nil
  end
  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}
  for _, v in ipairs(vehicles) do
    local vid = tonumber(v.vehicleId) or v.vehicleId
    if jobIdsMatch(vehicleId, vid) then
      return v
    end
  end
  return nil
end

-- Offer matching ----------------------------------------------------------------------------------

local function offerPwBounds(offer)
  local lo = tonumber(offer.classPwMin) or tonumber(offer.classHpMin) or 0
  local hi = tonumber(offer.classPwMax) or tonumber(offer.classHpMax) or lo
  if hi < lo then
    lo, hi = hi, lo
  end
  return lo, hi
end

-- Returns the fleet vehicle's effective power with the offer's bounds, or nil when either side is unknown.
local function fleetVehiclePwForOffer(racingTeamFleet, businessId, fleetVehicleId, offer)
  if type(offer) ~= "table" or fleetVehicleId == nil then
    return nil
  end
  local raw = getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId)
  if not raw then
    return nil
  end
  local pw = racingTeamFleet.getEffectiveTeamJobVehiclePw(businessId, raw)
  if not pw then
    return nil
  end
  local lo, hi = offerPwBounds(offer)
  return pw, lo, hi
end

local function sanctionedOfferMatchesFleetVehicle(racingTeamFleet, businessId, fleetVehicleId, offer)
  local pw, lo, hi = fleetVehiclePwForOffer(racingTeamFleet, businessId, fleetVehicleId, offer)
  if not pw then
    return false
  end
  return pw >= lo and pw <= hi
end

local function fleetVehicleOverpoweredForOffer(racingTeamFleet, businessId, fleetVehicleId, offer)
  local pw, _, hi = fleetVehiclePwForOffer(racingTeamFleet, businessId, fleetVehicleId, offer)
  if not pw then
    return false
  end
  return pw > hi
end

local function fleetVehicleEligibleForOffer(racingTeamFleet, businessId, fleetVehicleId, offer)
  local pw, _, hi = fleetVehiclePwForOffer(racingTeamFleet, businessId, fleetVehicleId, offer)
  if not pw then
    return false
  end
  return pw <= hi
end

-- Runtime hooks -----------------------------------------------------------------------------------


-- Other racing team parts read the current league and the driver list through rtState, so both are set here.
local function bindRuntimeHooks(rtState, parts)
  rtState.rtInternal.getCurrentLeague = function(businessId)
    return getCurrentLeague(rtState, parts, businessId)
  end
  rtState.rtInternal.leagueRankFromId = leagueRankFromId
  rtState.rtInternal.isLeagueAtLeast = isLeagueAtLeast
  rtState.rtInternal.isCurrentLeagueAtLeast = function(businessId, minRank)
    return isCurrentLeagueAtLeast(rtState, businessId, minRank)
  end
  rtState.loadRacingTeamDrivers = function(businessId)
    return loadRacingTeamDrivers(rtState, parts, businessId)
  end
end

-- Public API: delegates to the sibling parts ------------------------------------------------------

local function bindTabsAndClock(api, rtState)
  api.ensureTabsRegistered = function()
    return ensureTabsRegistered(rtState.businessType)
  end
  api.getCareerSimTime = getCareerSimTime
  api.getCareerSimTimeSeconds = getCareerSimTimeSeconds
  api.getRacingTeamLevelId = getRacingTeamLevelId
  api.getRacingTeamLevelInfo = function(levelId)
    return getRacingTeamLevelInfo(rtState, levelId)
  end
  api.resolveRacingTeamLeaderboardLevelIds = function()
    return resolveRacingTeamLeaderboardLevelIds()
  end
  api.shallowCopyTable = shallowCopyTable
  api.jobIdsMatch = jobIdsMatch
end

local function bindFleet(api, racingTeamFleet)
  api.sanctionedOfferMatchesFleetVehicle = function(businessId, fleetVehicleId, offer)
    return sanctionedOfferMatchesFleetVehicle(racingTeamFleet, businessId, fleetVehicleId, offer)
  end
  api.fleetVehicleOverpoweredForOffer = function(businessId, fleetVehicleId, offer)
    return fleetVehicleOverpoweredForOffer(racingTeamFleet, businessId, fleetVehicleId, offer)
  end
  api.fleetVehicleEligibleForOffer = function(businessId, fleetVehicleId, offer)
    return fleetVehicleEligibleForOffer(racingTeamFleet, businessId, fleetVehicleId, offer)
  end
  api.getBusinessVehicleRawByInventoryId = getBusinessVehicleRawByInventoryId
end

local function bindSiblingState(api, rtState, parts)
  api.getMaxPulledOutVehicles = function(businessId)
    return getMaxPulledOutVehicles(rtState, parts, businessId)
  end
  api.getMaxActiveJobs = function(businessId)
    return getMaxActiveJobs(rtState, parts, businessId)
  end
  api.getRacingTeamDriverCapacity = function(businessId)
    return getRacingTeamDriverCapacity(rtState, parts, businessId)
  end
  api.ensureRacingTeamDriverSlots = function(businessId)
    return ensureRacingTeamDriverSlots(rtState, parts, businessId)
  end
  api.ensureRacingDriverIdentity = ensureRacingDriverIdentity
  api.getRacingTeamDriversRawForUI = function(businessId)
    return getRacingTeamDriversRawForUI(rtState, parts, businessId)
  end
  api.getRacingTeamDriverById = function(businessId, techId)
    return getRacingTeamDriverById(rtState, businessId, techId)
  end
  api.getRacingTeamActiveJobByJobId = function(businessId, jobId)
    return getRacingTeamActiveJobByJobId(parts, businessId, jobId)
  end
  api.writeRacingTeamDrivers = function(businessId, currentSavePath, writer)
    return writeRacingTeamDrivers(rtState, parts, businessId, currentSavePath, writer)
  end
  api.saveRacingTeamDrivers = saveRacingTeamDrivers
end

-- Public API: instance construction ---------------------------------------------------------------

function part.new(inputs)
  local parts = inputs.parts
  local rtState = inputs.rtState
  local api = {}
  bindTabsAndClock(api, rtState)
  bindFleet(api, inputs.racingTeamFleet)
  bindSiblingState(api, rtState, parts)
  bindRuntimeHooks(rtState, parts)
  return api
end

return part
