-- Card table shell: bets, shoe, wallet, walking prompt and camera.
-- Read shared helpers, game registration, frame updates, public actions and game hooks.
local recordHand = require("overhaul/lib/progression/logbookFeed").register("overhaul.cardHandCompleted", {
  title = "Card hand completed", label = "Activities", icon = "checkmark"
}, "jobs/cardGames/cardGames.lua")

local M = {}

-- Config ----------------------------------------------------------------------------------------

local MIN_BET = 50
local RESHUFFLE_THRESHOLD = 0.5

local GAMBLING_SKILL_ATTRIBUTE_KEY = "careerSkills-gambling"
local GAMBLING_SKILL_XP_PER_DOLLAR_WIN = 9 / 130
local GAMBLING_DEFAULT_MAX_BET = 1000
local GAMBLING_BET_CAP_THRESHOLDS = {
  { xp = 301000, cap = 50000 },
  { xp = 225000, cap = 30000 },
  { xp = 162000, cap = 25000 },
  { xp = 113000, cap = 20000 },
  { xp = 75000,  cap = 15000 },
  { xp = 46000,  cap = 10000 },
  { xp = 26000,  cap = 5000 },
  { xp = 13000,  cap = 2500 },
  { xp = 5300,   cap = 2000 },
  { xp = 1400,   cap = 1500 },
}

local RANKS = {"A","2","3","4","5","6","7","8","9","10","J","Q","K"}
local SUITS = {"spades","hearts","clubs","diamonds"}
local FULL_DECK_SIZE = #RANKS * #SUITS

-- State -------------------------------------------------------------------------------------------

local loadedExtensions = {}
local activeGameId = nil
local activeMode = nil

local shoe = {}
local shoeSize = FULL_DECK_SIZE
local session

local walkCamWorldUp = vec3(0, 0, 1)
local gamblingTriggerPos = nil

local walkTurnAnim = {
  active = false,
  elapsed = 0,
  duration = 0.75,
  startDir3 = nil,
  endDir3 = nil,
}

-- Shared helpers ---------------------------------------------------------------------------------

local function triggerLookTargetWorldPos(triggerObj)
  if not triggerObj then return nil end
  local tid = triggerObj:getID()
  if tid and be:getObjectOOBBIsInitialized(tid) then
    return vec3(be:getObjectOOBBCenterXYZ(tid))
  end
  return vec3(triggerObj:getPosition())
end

local function updateWalkTurnAnim(dtReal)
  if not walkTurnAnim.active then return end
  if not gameplay_walk or not gameplay_walk.isWalking() then
    walkTurnAnim.active = false
    return
  end
  local sd, ed = walkTurnAnim.startDir3, walkTurnAnim.endDir3
  if not sd or not ed then
    walkTurnAnim.active = false
    return
  end
  walkTurnAnim.elapsed = walkTurnAnim.elapsed + dtReal
  local t = math.min(1, walkTurnAnim.elapsed / walkTurnAnim.duration)
  if t >= 1 then
    gameplay_walk.setRot(ed, walkCamWorldUp)
    walkTurnAnim.active = false
    return
  end
  local q0 = quatFromDir(sd, walkCamWorldUp)
  local q1 = quatFromDir(ed, walkCamWorldUp)
  local q = q0:nlerp(q1, t)
  local lookDir = vec3(q * vec3(0, 1, 0))
  if lookDir:length() > 1e-6 then
    lookDir = lookDir / lookDir:length()
    gameplay_walk.setRot(lookDir, walkCamWorldUp)
  end
end

local gamblingPromptLock = {
  frozenVehId = nil,
  inputBlocked = false,
}
local GAMBLING_PROMPT_FILTER = "cardGamesGamblingPrompt"
local gamblingPromptBlockedTemplate
local gamblingPromptVisible = false
local gamblingCameraActive = false

-- Table prompt and movement lock ----------------------------------------------------------------

local function getGamblingPromptBlockedTemplate()
  if gamblingPromptBlockedTemplate then return gamblingPromptBlockedTemplate end
  gamblingPromptBlockedTemplate = core_input_actionFilter.createActionTemplate({"gameCam", "walkingMode"})
  return gamblingPromptBlockedTemplate
end

local function applyGamblingPromptPlayerLock()
  if gamblingPromptLock.frozenVehId then return end
  if not gameplay_walk or not gameplay_walk.isWalking() then return end
  local veh = getPlayerVehicle(0)
  if not veh or not veh.getJBeamFilename or veh:getJBeamFilename() ~= "unicycle" then return end
  gamblingPromptLock.frozenVehId = veh:getID()
  veh:queueLuaCommand("controller.setFreeze(1)")
  local tmpl = getGamblingPromptBlockedTemplate()
  if tmpl then
    core_input_actionFilter.setGroup(GAMBLING_PROMPT_FILTER, tmpl)
    core_input_actionFilter.addAction(0, GAMBLING_PROMPT_FILTER, true)
    gamblingPromptLock.inputBlocked = true
  end
end

local function clearGamblingPromptPlayerLock()
  if gamblingPromptLock.inputBlocked then
    core_input_actionFilter.addAction(0, GAMBLING_PROMPT_FILTER, false)
    gamblingPromptLock.inputBlocked = false
  end
  if gamblingPromptLock.frozenVehId then
    local frozen = getObjectByID(gamblingPromptLock.frozenVehId)
    if frozen then
      frozen:queueLuaCommand("controller.setFreeze(0)")
    end
    gamblingPromptLock.frozenVehId = nil
  end
end

local function hideGamblingPrompt()
  if gamblingPromptVisible then
    gamblingPromptVisible = false
    guihooks.trigger("CardGamesGamblingPromptHide")
  end
  clearGamblingPromptPlayerLock()
end

-- Career wallet and betting ---------------------------------------------------------------------

local function careerMoneyApplies()
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    return false
  end
  return true
end

local function getWallet()
  if not careerMoneyApplies() then
    return 0
  end
  return math.floor(tonumber(overhaul_career_economy_playerAttributes.getAttributeValue("money")) or 0)
end

local function getGamblingMaxBet()
  if not careerMoneyApplies() then return GAMBLING_DEFAULT_MAX_BET end
  local value = tonumber(overhaul_career_economy_playerAttributes.getAttributeValue(GAMBLING_SKILL_ATTRIBUTE_KEY)) or 0
  for _, entry in ipairs(GAMBLING_BET_CAP_THRESHOLDS) do
    if value >= entry.xp then return entry.cap end
  end
  return GAMBLING_DEFAULT_MAX_BET
end

local function computeCareerPayout(modeState)
  if not modeState or not modeState.gameId then
    return 0
  end
  if modeState.gameId == "blackjack" then
    return math.floor(tonumber(modeState.payout) or 0)
  end
  if modeState.gameId == "rideTheBus" then
    return math.floor(tonumber(modeState.collectAmount) or 0)
  end
  return 0
end

local function careerBetLabel()
  if activeGameId == "blackjack" then
    return "Blackjack bet"
  end
  if activeGameId == "rideTheBus" then
    return "Ride the Bus bet"
  end
  return "Card games bet"
end

local function careerRefundLabel()
  if activeGameId == "blackjack" then
    return "Blackjack bet refund"
  end
  if activeGameId == "rideTheBus" then
    return "Ride the Bus bet refund"
  end
  return "Card games bet refund"
end

local function careerPayoutLabel(modeState)
  if not modeState or not modeState.gameId then
    return "Card games payout"
  end
  local r = modeState.result
  if modeState.gameId == "blackjack" then
    if r == "blackjack" then
      return "Blackjack win (natural)"
    end
    if r == "win" or r == "dealer_bust" then
      return "Blackjack win"
    end
    if r == "push" then
      return "Blackjack push"
    end
    if r == "bust" then
      return "Blackjack bust"
    end
    if r == "lose" then
      return "Blackjack lose"
    end
    return "Blackjack payout"
  end
  if modeState.gameId == "rideTheBus" then
    if r == "win" then
      return "Ride the Bus win"
    end
    if r == "forfeit" then
      return "Ride the Bus cash out"
    end
    if r == "lose" then
      return "Ride the Bus lose"
    end
    if r == "timeout" then
      return "Ride the Bus timeout"
    end
    return "Ride the Bus payout"
  end
  return "Card games payout"
end

local function careerTrySettle(modeState)
  if not careerMoneyApplies() then
    return
  end
  if session.phase ~= "playing" then
    return
  end
  if not modeState or modeState.phase ~= "resolved" then
    return
  end
  if not session.careerChargedThisRound or session.careerPaidThisRound then
    return
  end
  -- The table outlives payment; a resolved hand still settles through its legacy wallet during a reload.
  local payment = overhaul_career_economy_payment
  local payout = computeCareerPayout(modeState)
  local paidPayout = 0
  if payout > 0 then
    local change = {money = payout}
    local reason = {label = careerPayoutLabel(modeState), tags = {"cardGames"}}
    if payment and type(payment.payout) == "function" then
      local accepted, problem = payment.payout(require("overhaul/lib/finance/metadata").tagPayout({amount = change.money, reason = reason}, "gambling", {vehicleRelated = false}))
      -- Legacy settlement continued after a refused attribute mutation; never retry the winnings.
      if accepted ~= true then log("W", "cardGames", "Winnings payout refused: " .. tostring(problem))
      else paidPayout = payout end
    else
      overhaul_career_economy_playerAttributes.addAttributes(change, require("overhaul/lib/finance/metadata").tag(reason, "gambling", {vehicleRelated = false}))
      paidPayout = payout
    end
  end
  session.careerPaidThisRound = true
  recordHand({detail = careerPayoutLabel(modeState), money = paidPayout - (session.careerChargedThisRound or 0)})
  if not session.gamblingSkillXpGranted then
    local charged = session.careerChargedThisRound or 0
    local net = payout - charged
    local xp = 0
    if net > 0 then
      xp = math.floor(GAMBLING_SKILL_XP_PER_DOLLAR_WIN * net)
    elseif net < 0 then
      xp = math.floor(0.30 * GAMBLING_SKILL_XP_PER_DOLLAR_WIN * math.abs(net))
    end
    if xp > 0 then
      local change = {[GAMBLING_SKILL_ATTRIBUTE_KEY] = xp}
      local reason = {tags = {"cardGames", "gambling"}}
      if payment and type(payment.payout) == "function" then
        local accepted, problem = payment.payout({xp = change, reason = reason})
        if accepted ~= true then log("W", "cardGames", "Gambling progression refused: " .. tostring(problem)) end
      else
        overhaul_career_economy_playerAttributes.addAttributes(change, reason)
      end
    end
    session.gamblingSkillXpGranted = true
  end
end

local function careerRefundUnsettled()
  if session.phase == "playing" and session.careerChargedThisRound and not session.careerPaidThisRound
      and activeMode and activeMode.resolveOnLeave and activeMode.getState then
    activeMode.resolveOnLeave()
    careerTrySettle(activeMode.getState())
  end
  if careerMoneyApplies() then
    if session.careerChargedThisRound and not session.careerPaidThisRound then
      overhaul_career_economy_playerAttributes.addAttributes({ money = session.careerChargedThisRound }, require("overhaul/lib/finance/metadata").tag({ label = careerRefundLabel(), tags = { "cardGames" } }, "refund", {vehicleRelated = false}))
    end
  end
  session.careerChargedThisRound = nil
  session.careerPaidThisRound = false
  session.gamblingSkillXpGranted = false
end

local function clampBetForCareer()
  if not careerMoneyApplies() then
    return
  end
  local maxBet = math.min(getGamblingMaxBet(), math.max(0, getWallet()))
  if maxBet < MIN_BET then
    session.bet = math.max(0, maxBet)
    session.betError = "insufficientFunds"
    return
  end
  session.bet = math.max(MIN_BET, math.min(maxBet, session.bet))
  session.betError = nil
end

-- Card shoe -------------------------------------------------------------------------------------

local function buildShoe()
  shoe = {}
  for _, suit in ipairs(SUITS) do
    for _, rank in ipairs(RANKS) do
      table.insert(shoe, {rank = rank, suit = suit})
    end
  end
  shoeSize = #shoe
end

local function shuffleShoe()
  for i = #shoe, 2, -1 do
    local j = math.random(1, i)
    shoe[i], shoe[j] = shoe[j], shoe[i]
  end
end

local function rebuildAndShuffleShoe()
  buildShoe()
  shuffleShoe()
  session.shuffleCounter = (session.shuffleCounter or 0) + 1
end

local function needsReshuffle()
  return #shoe < math.floor(shoeSize * RESHUFFLE_THRESHOLD)
end

local function ensureShoe()
  if #shoe == 0 or needsReshuffle() then
    rebuildAndShuffleShoe()
  end
end

local function draw()
  if #shoe == 0 then
    rebuildAndShuffleShoe()
  end
  return table.remove(shoe)
end

session = {
  bet = 100,
  phase = "idle",
  shuffleCounter = 0,
  careerChargedThisRound = nil,
  careerPaidThisRound = false,
  gamblingSkillXpGranted = false,
  betError = nil,
}

local modeRegistry = {}

-- Game loading and publication ------------------------------------------------------------------

local function loadExtensions()
  loadedExtensions = require('overhaul/lib/shell/childExtensions').load({
    'overhaul_jobs_cardGames_blackjack',
    'overhaul_jobs_cardGames_rideTheBus',
  }) or loadedExtensions
end

local function unloadExtensions()
  if require('overhaul/lib/shell/childExtensions').unload(loadedExtensions) == false then return false end
  loadedExtensions = {}
end

local function pushState()
  local modeState = {}
  if activeMode and activeMode.getState then
    modeState = activeMode.getState()
  end
  careerTrySettle(modeState)
  local careerActive = careerMoneyApplies()
  local balance = nil
  local maxBetForUi = getGamblingMaxBet()
  if careerActive then
    balance = getWallet()
    maxBetForUi = math.min(maxBetForUi, math.max(0, balance))
  end
  local state = {
    gameId = activeGameId,
    phase = session.phase,
    bet = session.bet,
    shuffleCounter = session.shuffleCounter,
    mode = modeState,
    careerActive = careerActive,
    balance = balance,
    maxBet = maxBetForUi,
    betError = session.betError,
  }
  guihooks.trigger("cardGamesState", state)
end

-- Game registration -------------------------------------------------------------------------------

local function register(gameId, api)
  modeRegistry[gameId] = api
end

local function open(gameId)
  local api = modeRegistry[gameId]
  if not api then
    log("E", "cardGames", "Unknown game: " .. tostring(gameId))
    return
  end
  careerRefundUnsettled()
  activeGameId = gameId
  activeMode = api
  session.phase = "betting"
  session.bet = 100
  session.betError = nil
  session.careerChargedThisRound = nil
  session.careerPaidThisRound = false
  session.gamblingSkillXpGranted = false
  if activeMode.reset then activeMode.reset() end
  clampBetForCareer()
  pushState()
end

local function close()
  careerRefundUnsettled()
  if activeMode and activeMode.reset then activeMode.reset() end
  activeGameId = nil
  activeMode = nil
  session.phase = "idle"
  session.betError = nil
  session.careerChargedThisRound = nil
  session.careerPaidThisRound = false
  session.gamblingSkillXpGranted = false
  pushState()
end

local function setBet(amount)
  if session.phase ~= "betting" then return end
  amount = math.floor(tonumber(amount) or session.bet)
  local maxBet = getGamblingMaxBet()
  if careerMoneyApplies() then
    maxBet = math.min(maxBet, math.max(0, getWallet()))
  end
  if careerMoneyApplies() and maxBet < MIN_BET then
    session.bet = math.max(0, maxBet)
    session.betError = "insufficientFunds"
    pushState()
    return
  end
  amount = math.max(MIN_BET, math.min(maxBet, amount))
  session.bet = amount
  session.betError = nil
  pushState()
end

local function confirmBet()
  if session.phase ~= "betting" then return end
  if not activeMode then return end
  session.betError = nil
  if careerMoneyApplies() then
    local w = getWallet()
    if session.bet < MIN_BET or session.bet > w then
      session.betError = "insufficientFunds"
      pushState()
      return
    end
    overhaul_career_economy_playerAttributes.addAttributes({ money = -session.bet }, require("overhaul/lib/finance/metadata").tag({ label = careerBetLabel(), tags = { "cardGames" } }, "gambling", {vehicleRelated = false}))
    session.careerChargedThisRound = session.bet
    session.careerPaidThisRound = false
    session.gamblingSkillXpGranted = false
  end
  ensureShoe()
  session.phase = "playing"
  if activeMode.deal then activeMode.deal(session.bet) end
  pushState()
end

local function action(name, payload)
  if not activeMode then return end
  if activeMode.onAction then
    activeMode.onAction(name, payload)
  end
  pushState()
end

local function newRound()
  if not activeMode then return end
  careerRefundUnsettled()
  session.phase = "betting"
  session.betError = nil
  if activeMode.reset then activeMode.reset() end
  clampBetForCareer()
  pushState()
end

local function requestSync()
  pushState()
end

-- Per-frame update --------------------------------------------------------------------------------

local function onUpdate(dtReal, dtSim, dtRaw)
  updateWalkTurnAnim(dtReal)
  if activeMode and activeMode.update then
    activeMode.update(dtReal, dtSim, dtRaw)
  end
end

local function startOrientWalkingTowardTrigger(triggerObj)
  if not gameplay_walk or not gameplay_walk.isWalking() then return end
  if not triggerObj then return end
  if not getPlayerVehicle(0) then return end
  local tpos = triggerLookTargetWorldPos(triggerObj)
  if not tpos then return end
  local camPos = vec3(core_camera.getPosition())
  local endDir3 = tpos - camPos
  local elen = endDir3:length()
  if elen < 1e-3 then return end
  endDir3 = endDir3 / elen
  local cq = core_camera.getQuat()
  local startDir3 = vec3(cq * vec3(0, 1, 0))
  local slen = startDir3:length()
  if slen < 1e-3 then return end
  startDir3 = startDir3 / slen
  if 1 - startDir3:dot(endDir3) < 1e-6 then
    gameplay_walk.setRot(endDir3, walkCamWorldUp)
    walkTurnAnim.active = false
    walkTurnAnim.startDir3 = nil
    walkTurnAnim.endDir3 = nil
    return
  end
  walkTurnAnim.startDir3 = startDir3
  walkTurnAnim.endDir3 = endDir3
  walkTurnAnim.elapsed = 0
  walkTurnAnim.active = true
end

local function onBeamNGTrigger(data)
  if not data.triggerName or not data.triggerName:match("^cardGames_") then return end
  if data.subjectID ~= be:getPlayerVehicleID(0) then return end
  if data.event == "exit" then
    if gamblingPromptVisible and not gamblingCameraActive then hideGamblingPrompt() end
    return
  end
  if data.event ~= "enter" then return end
  if gamblingCameraActive or activeGameId then return end
  local triggerObj = (data.triggerID and scenetree.findObjectById(data.triggerID))
    or (data.triggerName and scenetree.findObject(data.triggerName))
  if not triggerObj then return end
  gamblingTriggerPos = vec3(triggerObj:getPosition())
  applyGamblingPromptPlayerLock()
  startOrientWalkingTowardTrigger(triggerObj)
  gamblingPromptVisible = true
  guihooks.trigger("CardGamesGamblingPromptShow")
end

-- Lifecycle and camera cleanup ------------------------------------------------------------------

local function restoreGamblingPromptWorld()
  gamblingCameraActive = false
  commands.setGameCamera()
  hideGamblingPrompt()
end

local function stopGambleCameraAnim()
  restoreGamblingPromptWorld()
end

local function leaveTableFromUi()
  close()
  restoreGamblingPromptWorld()
  gamblingTriggerPos = nil
end

local function startGambleCameraAnim()
  if not gamblingTriggerPos then return end
  -- The prompt UI already closed itself; keep the player lock until the table is left.
  gamblingPromptVisible = false
  local sq = core_camera.getQuat()
  local tpos = vec3(gamblingTriggerPos)
  local ep = vec3(tpos.x, tpos.y, tpos.z + 0.5)
  local horizFwd = vec3(sq * vec3(0, 1, 0))
  horizFwd = vec3(horizFwd.x, horizFwd.y, 0)
  if horizFwd:length() < 1e-3 then horizFwd = vec3(0, 1, 0) end
  horizFwd = horizFwd / horizFwd:length()
  local lookDir = tpos - ep
  if lookDir:length() < 1e-3 then lookDir = vec3(0, 0, -1) end
  lookDir = lookDir / lookDir:length()
  local eq = quatFromDir(lookDir, horizFwd)
  commands.setFreeCamera()
  core_camera.setPosition(0, ep)
  core_camera.setRotation(0, eq)
  core_camera.resetCamera(0)
  gamblingCameraActive = true
end

-- ESC / pause menu (or any non-play screen) must never leave the prompt on top of the UI
local function onUiChangedState(toState)
  if not gamblingPromptVisible or gamblingCameraActive then return end
  if toState ~= "play" then hideGamblingPrompt() end
end

local function onClientEndMission()
  walkTurnAnim.active = false
  gamblingTriggerPos = nil
  if gamblingCameraActive then
    stopGambleCameraAnim()
  else
    hideGamblingPrompt()
  end
  if activeGameId then close() end
end

local function onExtensionLoaded()
  loadExtensions()
end

local function onExtensionUnloaded()
  walkTurnAnim.active = false
  gamblingTriggerPos = nil
  stopGambleCameraAnim()
  close()
  unloadExtensions()
end

-- Public API and game hooks ----------------------------------------------------------------------

M.draw = draw
M.ensureShoe = ensureShoe
M.getShoeCount = function() return #shoe end
M.getSessionBet = function() return session.bet end
M.register = register
M.open = open
M.close = close
M.setBet = setBet
M.confirmBet = confirmBet
M.action = action
M.newRound = newRound
M.requestSync = requestSync
M.pushState = pushState
M.onUpdate = onUpdate
M.onBeamNGTrigger = onBeamNGTrigger
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUiChangedState = onUiChangedState
M.onClientEndMission = onClientEndMission
M.clearGamblingPromptPlayerLock = function()
  gamblingPromptVisible = false
  clearGamblingPromptPlayerLock()
end
M.hideGamblingPrompt = hideGamblingPrompt
M.startGambleCameraAnim = startGambleCameraAnim
M.stopGambleCameraAnim = stopGambleCameraAnim
M.leaveTable = leaveTableFromUi

-- functions above (no projection: the state push settles a resolved round).
M.activity = require('overhaul/jobs/cardGames/activity')(M)

return M
