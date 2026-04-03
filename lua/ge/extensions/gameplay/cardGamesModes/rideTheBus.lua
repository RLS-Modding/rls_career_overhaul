local M = {}

local RANK_VALUES = {A=14, ["2"]=2,["3"]=3,["4"]=4,["5"]=5,["6"]=6,["7"]=7,["8"]=8,["9"]=9,["10"]=10,J=11,Q=12,K=13}

local ROUND_KINDS = {"redblack", "highlow", "inout", "suit"}
local ROUND_LABELS = {redblack="Red or Black", highlow="Higher or Lower", inout="Inside or Outside", suit="Pick a Suit"}
local ROUND_MULTIPLIERS = {1.5, 2, 4, 20}
local TIMER_DURATION = 10

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

local REVEAL_DELAY = 0.82
local INITIAL_DEAL_DELAY = 2.15

local function draw()
  return gameplay_cardGames.draw()
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
end

local function startTimer()
  timerDeadline = os.clock() + TIMER_DURATION
end

local function timerRemaining()
  if not timerDeadline then return nil end
  local r = timerDeadline - os.clock()
  return r > 0 and r or 0
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
    local c = draw()
    c.faceUp = false
    c.index = i
    table.insert(cards, c)
  end

  phase = "dealing"
  timerDeadline = nil
  dealFinishDeadline = os.clock() + INITIAL_DEAL_DELAY
end

local function isRed(suit)
  return RED_SUITS[suit] == true
end

local function resolveChoice(choiceKind, choice, card, prevCard)
  local rv = RANK_VALUES[card.rank]

  if choiceKind == "redblack" then
    local cardIsRed = isRed(card.suit)
    return (choice == "red" and cardIsRed) or (choice == "black" and not cardIsRed)

  elseif choiceKind == "highlow" then
    if not prevCard then return false end
    local pv = RANK_VALUES[prevCard.rank]
    if choice == "higher" then return rv > pv
    elseif choice == "lower" then return rv < pv
    end
    return false

  elseif choiceKind == "inout" then
    if currentRound < 3 then return false end
    local v1 = RANK_VALUES[cards[1].rank]
    local v2 = RANK_VALUES[cards[2].rank]
    local lo = math.min(v1, v2)
    local hi = math.max(v1, v2)
    if choice == "inside" then return rv >= lo and rv <= hi
    elseif choice == "outside" then return rv < lo or rv > hi
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
  lastFlipTime = os.clock()

  local choiceKind = ROUND_KINDS[currentRound]
  local prevCard = currentRound > 1 and cards[currentRound - 1] or nil
  pendingChoiceCorrect = resolveChoice(choiceKind, choice, card, prevCard)
  phase = "revealing"
  revealDeadline = os.clock() + REVEAL_DELAY
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
  for _, c in ipairs(cards) do
    table.insert(serialCards, {
      rank = c.rank,
      suit = c.suit,
      faceUp = c.faceUp,
      index = c.index,
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
  if phase == "dealing" and dealFinishDeadline and os.clock() >= dealFinishDeadline then
    dealFinishDeadline = nil
    advanceRound()
    if gameplay_cardGames and gameplay_cardGames.pushState then
      gameplay_cardGames.pushState()
    end
    return
  end

  if phase == "revealing" and revealDeadline and os.clock() >= revealDeadline then
    revealDeadline = nil
    local correct = pendingChoiceCorrect
    pendingChoiceCorrect = nil

    if correct then
      advanceRound()
    else
      phase = "resolved"
      result = "lose"
    end

    if gameplay_cardGames then gameplay_cardGames.pushState() end
    return
  end

  if phase == "choosing" and timerDeadline then
    if os.clock() >= timerDeadline then
      timerDeadline = nil
      local defaultChoice = getDefaultChoice()
      if defaultChoice then
        choose(defaultChoice)
      else
        phase = "resolved"
        result = "timeout"
      end
      if gameplay_cardGames then gameplay_cardGames.pushState() end
    end
  end
end

local function onExtensionLoaded()
  if gameplay_cardGames and gameplay_cardGames.register then
    gameplay_cardGames.register("rideTheBus", M)
  end
end

M.reset = reset
M.deal = deal
M.getState = getState
M.onAction = onAction
M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded

return M
