local M = {}

local loadedExtensions = {}
local activeGameId = nil
local activeMode = nil

local MIN_BET = 50
local MAX_BET = 1000
local RESHUFFLE_THRESHOLD = 0.5

local RANKS = {"A","2","3","4","5","6","7","8","9","10","J","Q","K"}
local SUITS = {"spades","hearts","clubs","diamonds"}
local FULL_DECK_SIZE = #RANKS * #SUITS

local shoe = {}
local shoeSize = FULL_DECK_SIZE
local session

local function careerMoneyApplies()
  if not career_career or not career_career.isActive or not career_career.isActive() then
    return false
  end
  if not career_modules_playerAttributes or not career_modules_playerAttributes.getAttributeValue then
    return false
  end
  return true
end

local function getWallet()
  if not careerMoneyApplies() then
    return 0
  end
  return math.floor(tonumber(career_modules_playerAttributes.getAttributeValue("money")) or 0)
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

local function careerRefundUnsettled()
  if careerMoneyApplies() then
    if session.careerChargedThisRound and not session.careerPaidThisRound then
      career_modules_playerAttributes.addAttributes(
        { money = session.careerChargedThisRound },
        { label = careerRefundLabel(), tags = { "cardGames" } }
      )
    end
  end
  session.careerChargedThisRound = nil
  session.careerPaidThisRound = false
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
  local payout = computeCareerPayout(modeState)
  if payout > 0 then
    career_modules_playerAttributes.addAttributes(
      { money = payout },
      { label = careerPayoutLabel(modeState), tags = { "cardGames" } }
    )
  end
  session.careerPaidThisRound = true
end

local function clampBetForCareer()
  if not careerMoneyApplies() then
    return
  end
  local maxBet = math.min(MAX_BET, math.max(0, getWallet()))
  if maxBet < MIN_BET then
    session.bet = math.max(0, maxBet)
    session.betError = "insufficientFunds"
    return
  end
  session.bet = math.max(MIN_BET, math.min(maxBet, session.bet))
  session.betError = nil
end

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
  betError = nil,
}

local modeRegistry = {}

local function loadExtensions()
  local basePath = "/lua/ge/extensions/gameplay/cardGamesModes/"
  local files = FS:findFiles(basePath, "*.lua", -1, true, false)
  if files then
    for _, filePath in ipairs(files) do
      local filename = string.match(filePath, "([^/]+)%.lua$")
      if filename then
        local extensionName = "gameplay_cardGamesModes_" .. filename
        setExtensionUnloadMode(extensionName, "manual")
        extensions.unload(extensionName)
        table.insert(loadedExtensions, extensionName)
      end
    end
  end
  loadManualUnloadExtensions()
end

local function unloadExtensions()
  for _, extensionName in ipairs(loadedExtensions) do
    extensions.unload(extensionName)
  end
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
  local maxBetForUi = MAX_BET
  if careerActive then
    balance = getWallet()
    maxBetForUi = math.min(MAX_BET, math.max(0, balance))
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
  pushState()
end

local function setBet(amount)
  if session.phase ~= "betting" then return end
  amount = math.floor(tonumber(amount) or session.bet)
  local maxBet = MAX_BET
  if careerMoneyApplies() then
    maxBet = math.min(MAX_BET, math.max(0, getWallet()))
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
    career_modules_playerAttributes.addAttributes(
      { money = -session.bet },
      { label = careerBetLabel(), tags = { "cardGames" } }
    )
    session.careerChargedThisRound = session.bet
    session.careerPaidThisRound = false
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

local function onUpdate(dtReal, dtSim, dtRaw)
  if activeMode and activeMode.onUpdate then
    activeMode.onUpdate(dtReal, dtSim, dtRaw)
  end
end

local function onExtensionLoaded()
  loadExtensions()
end

local function onExtensionUnloaded()
  close()
  unloadExtensions()
end

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
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
