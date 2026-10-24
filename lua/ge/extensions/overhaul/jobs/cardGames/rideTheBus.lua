-- Ride the Bus round rules and card choices.
-- Read round setup, choice handling and settlement; the table shell owns the shoe and wallet.
local M = {}

local RANK_VALUES = {A=14, ["2"]=2,["3"]=3,["4"]=4,["5"]=5,["6"]=6,["7"]=7,["8"]=8,["9"]=9,["10"]=10,J=11,Q=12,K=13}

local ROUND_KINDS = {"redblack", "highlow", "inout", "suit"}
local ROUND_LABELS = {redblack="Red or Black", highlow="Higher or Lower", inout="Inside or Outside", suit="Pick a Suit"}
local ROUND_MULTIPLIERS = {1.5, 2, 4, 20}
local CHOICE_TIMEOUT_SECONDS = 10

local RED_SUITS = {hearts = true, diamonds = true}

local cards = {}
local currentRound = 0
local phase = "idle"
local bet = 0
local result = nil
local timerDeadline = nil
local lastFlipTime = nil
local revealDeadline = nil
local pendingChoiceCorrect = nil
local dealFinishDeadline = nil
local gameTime = 0

local REVEAL_DELAY_SECONDS = 0.82
local INITIAL_DEAL_DELAY_SECONDS = 2.15

-- Shared helpers ---------------------------------------------------------------------------------

local function draw()
  return overhaul_jobs_cardGames_cardGames.draw()
end

local function reset()
  cards = {}
  currentRound = 0
  phase = "idle"
  bet = 0
  result = nil
  timerDeadline = nil
  lastFlipTime = nil
  revealDeadline = nil
  pendingChoiceCorrect = nil
  dealFinishDeadline = nil
  gameTime = 0
end

local function startTimer()
  timerDeadline = gameTime + CHOICE_TIMEOUT_SECONDS
end

local function timerRemaining()
  if not timerDeadline then return nil end
  local remainingSeconds = timerDeadline - gameTime
  return remainingSeconds > 0 and remainingSeconds or 0
end

local function getRoundsCleared()
  if result == "win" then
    return 4
  end
  if phase == "choosing" then
    return math.max(0, currentRound - 1)
  end
  if result == "forfeit" then
    return math.max(0, currentRound - 1)
  end
  return 0
end

local function getCollectAmount()
  local cleared = getRoundsCleared()
  if cleared == 0 and (phase == "choosing" or result == "forfeit") then
    return bet
  end
  local multiplier = ROUND_MULTIPLIERS[cleared] or 0
  return bet * multiplier
end

local function advanceRound()
  currentRound = currentRound + 1
  if currentRound > 4 then
    phase = "resolved"
    result = "win"
    return
  end
  phase = "choosing"
  startTimer()
end

local function deal(betAmount)
  bet = betAmount
  cards = {}
  result = nil
  currentRound = 0
  for i = 1, 4 do
    local card = draw()
    card.faceUp = false
    card.index = i
    table.insert(cards, card)
  end
  phase = "dealing"
  timerDeadline = nil
  dealFinishDeadline = gameTime + INITIAL_DEAL_DELAY_SECONDS
end

local function isRed(suit)
  return RED_SUITS[suit] == true
end

local function resolveChoice(choiceKind, choice, card, prevCard)
  local rankValue = RANK_VALUES[card.rank]
  if choiceKind == "redblack" then
    local cardIsRed = isRed(card.suit)
    return (choice == "red" and cardIsRed) or (choice == "black" and not cardIsRed)
  elseif choiceKind == "highlow" then
    if not prevCard then return false end
    local previousRankValue = RANK_VALUES[prevCard.rank]
    if choice == "higher" then return rankValue > previousRankValue
    elseif choice == "lower" then return rankValue < previousRankValue
    end
    return false
  elseif choiceKind == "inout" then
    if currentRound < 3 then return false end
    local v1 = RANK_VALUES[cards[1].rank]
    local v2 = RANK_VALUES[cards[2].rank]
    local lo = math.min(v1, v2)
    local hi = math.max(v1, v2)
    if choice == "inside" then return rankValue >= lo and rankValue <= hi
    elseif choice == "outside" then return rankValue < lo or rankValue > hi
    end
    return false
  elseif choiceKind == "suit" then
    return card.suit == choice
  end
  return false
end

local function choose(choice)
  if phase ~= "choosing" then return end
  local card = cards[currentRound]
  if not card then return end
  timerDeadline = nil
  card.faceUp = true
  lastFlipTime = gameTime
  local choiceKind = ROUND_KINDS[currentRound]
  local prevCard = currentRound > 1 and cards[currentRound - 1] or nil
  pendingChoiceCorrect = resolveChoice(choiceKind, choice, card, prevCard)
  phase = "revealing"
  revealDeadline = gameTime + REVEAL_DELAY_SECONDS
end

local function revealOneCardOnForfeit()
  local idx = nil
  if phase == "dealing" then
    idx = 1
  elseif phase == "choosing" and currentRound >= 1 and currentRound <= 4 then
    idx = currentRound
  elseif phase == "revealing" then
    idx = currentRound + 1
    if idx > 4 then
      idx = nil
    end
  end
  if idx and cards[idx] and not cards[idx].faceUp then
    cards[idx].faceUp = true
  end
end

local function endGame()
  if phase == "resolved" or phase == "idle" then return end
  timerDeadline = nil
  revealDeadline = nil
  pendingChoiceCorrect = nil
  dealFinishDeadline = nil
  revealOneCardOnForfeit()
  phase = "resolved"
  result = "forfeit"
end

local function resolveOnLeave()
  if phase == "idle" or phase == "resolved" then return end
  if phase == "revealing" then
    local correct = pendingChoiceCorrect
    revealDeadline = nil
    pendingChoiceCorrect = nil
    if not correct then
      phase = "resolved"
      result = "lose"
      return
    end
    advanceRound()
    if phase == "resolved" then return end
  end
  endGame()
end

local function getDefaultChoice()
  local choiceKind = ROUND_KINDS[currentRound]
  if choiceKind == "redblack" then return "red" end
  if choiceKind == "highlow" then return "higher" end
  if choiceKind == "inout" then return "inside" end
  if choiceKind == "suit" then return "spades" end
  return nil
end

local function getState()
  local serialCards = {}
  for _, card in ipairs(cards) do
    table.insert(serialCards, {
      rank = card.rank,
      suit = card.suit,
      faceUp = card.faceUp,
      index = card.index,
    })
  end
  local choiceKind = nil
  local choiceLabel = nil
  if phase == "choosing" and currentRound >= 1 and currentRound <= 4 then
    choiceKind = ROUND_KINDS[currentRound]
    choiceLabel = ROUND_LABELS[choiceKind]
  end
  return {
    gameId = "rideTheBus",
    phase = phase,
    cards = serialCards,
    currentRound = currentRound,
    choiceKind = choiceKind,
    choiceLabel = choiceLabel,
    timerRemaining = timerRemaining(),
    result = result,
    bet = bet,
    roundsCleared = getRoundsCleared(),
    collectAmount = getCollectAmount(),
  }
end

local function onAction(name, payload)
  if name == "choose" then
    choose(payload)
  elseif name == "endGame" then
    endGame()
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  gameTime = gameTime + math.max(0, dtSim or 0)
  if phase == "dealing" and dealFinishDeadline and gameTime >= dealFinishDeadline then
    dealFinishDeadline = nil
    advanceRound()
    if overhaul_jobs_cardGames_cardGames and overhaul_jobs_cardGames_cardGames.pushState then
      overhaul_jobs_cardGames_cardGames.pushState()
    end
    return
  end
  if phase == "revealing" and revealDeadline and gameTime >= revealDeadline then
    revealDeadline = nil
    local correct = pendingChoiceCorrect
    pendingChoiceCorrect = nil
    if correct then
      advanceRound()
    else
      phase = "resolved"
      result = "lose"
    end
    if overhaul_jobs_cardGames_cardGames then overhaul_jobs_cardGames_cardGames.pushState() end
    return
  end
  if phase == "choosing" and timerDeadline then
    if gameTime >= timerDeadline then
      timerDeadline = nil
      local defaultChoice = getDefaultChoice()
      if defaultChoice then
        choose(defaultChoice)
      else
        phase = "resolved"
        result = "timeout"
      end
      if overhaul_jobs_cardGames_cardGames then overhaul_jobs_cardGames_cardGames.pushState() end
    end
  end
end

local function onExtensionLoaded()
  if overhaul_jobs_cardGames_cardGames and overhaul_jobs_cardGames_cardGames.register then
    overhaul_jobs_cardGames_cardGames.register("rideTheBus", M)
  end
end

-- Public API and game hooks ----------------------------------------------------------------------

M.reset = reset
M.deal = deal
M.getState = getState
M.onAction = onAction
M.resolveOnLeave = resolveOnLeave
M.update = onUpdate
M.onExtensionLoaded = onExtensionLoaded

return M
