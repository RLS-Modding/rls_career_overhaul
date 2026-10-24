-- Blackjack hand rules and player actions.
-- Read deal, action and round settlement; the table shell owns the shoe and wallet.
local M = {}

local playerHand = {}
local dealerHand = {}
local phase = "idle"
local bet = 0
local result = nil
local pendingAction = nil
local pendingDeadline = nil
local gameTime = 0

local INITIAL_DEAL_DELAY_SECONDS = 2.05
local PLAYER_HIT_DELAY_SECONDS = 0.52
local DEALER_REVEAL_DELAY_SECONDS = 0.82
local DEALER_HIT_DELAY_SECONDS = 0.52

-- Shared helpers ---------------------------------------------------------------------------------

local function cardValue(card)
  local rank = card.rank
  if rank == "A" then return 11 end
  if rank == "J" or rank == "Q" or rank == "K" then return 10 end
  return tonumber(rank)
end

local function handValue(hand, faceUpOnly)
  local total = 0
  local aces = 0
  for _, card in ipairs(hand) do
    if not faceUpOnly or card.faceUp then
      local value = cardValue(card)
      total = total + value
      if card.rank == "A" then aces = aces + 1 end
    end
  end
  while total > 21 and aces > 0 do
    total = total - 10
    aces = aces - 1
  end
  return total
end

local function isSoft17(hand)
  local total = 0
  local aces = 0
  for _, card in ipairs(hand) do
    local value = cardValue(card)
    total = total + value
    if card.rank == "A" then aces = aces + 1 end
  end
  while total > 21 and aces > 1 do
    total = total - 10
    aces = aces - 1
  end
  return total == 17 and aces >= 1
end

local function shouldDealerHit(hand)
  local dealerTotal = handValue(hand, false)
  if dealerTotal < 17 then return true end
  return false
end

local function draw()
  return overhaul_jobs_cardGames_cardGames.draw()
end

local function reset()
  playerHand = {}
  dealerHand = {}
  phase = "idle"
  bet = 0
  result = nil
  pendingAction = nil
  pendingDeadline = nil
  gameTime = 0
end

local function resolveResult()
  local playerTotal = handValue(playerHand, false)
  local dealerTotal = handValue(dealerHand, false)
  local playerNatural = playerTotal == 21 and #playerHand == 2
  local dealerNatural = dealerTotal == 21 and #dealerHand == 2
  if playerNatural and dealerNatural then return "push" end
  if dealerNatural then return "lose" end
  if playerNatural then return "blackjack" end
  if playerTotal > 21 then return "bust" end
  if dealerTotal > 21 then return "dealer_bust" end
  if playerTotal > dealerTotal then return "win" end
  if playerTotal < dealerTotal then return "lose" end
  return "push"
end

local function schedule(action, delaySeconds)
  pendingAction = action
  pendingDeadline = gameTime + delaySeconds
end

local function clearPending()
  pendingAction = nil
  pendingDeadline = nil
end

local function startDealerReveal()
  if dealerHand[2] then
    dealerHand[2].faceUp = true
  end
  phase = "dealer_reveal"
  schedule("dealer_continue", DEALER_REVEAL_DELAY_SECONDS)
end

local function continueDealerTurn()
  if shouldDealerHit(dealerHand) then
    local card = draw()
    card.faceUp = true
    table.insert(dealerHand, card)
    phase = "dealer_hit"
    schedule("dealer_continue", DEALER_HIT_DELAY_SECONDS)
    return
  end
  phase = "resolved"
  result = resolveResult()
end

local function finishInitialDeal()
  if handValue(playerHand, false) == 21 or handValue(dealerHand, false) == 21 then
    startDealerReveal()
    return
  end
  phase = "player_turn"
end

local function finishPlayerHit()
  local playerTotal = handValue(playerHand, false)
  if playerTotal > 21 then
    for _, dealerCard in ipairs(dealerHand) do
      dealerCard.faceUp = true
    end
    phase = "resolved"
    result = "bust"
    return
  end
  if playerTotal == 21 then
    startDealerReveal()
    return
  end
  phase = "player_turn"
end

local function deal(betAmount)
  bet = betAmount
  playerHand = {}
  dealerHand = {}
  result = nil
  clearPending()
  local p1 = draw(); p1.faceUp = true
  table.insert(playerHand, p1)
  local d1 = draw(); d1.faceUp = true
  table.insert(dealerHand, d1)
  local p2 = draw(); p2.faceUp = true
  table.insert(playerHand, p2)
  local d2 = draw(); d2.faceUp = false
  table.insert(dealerHand, d2)
  phase = "dealing"
  schedule("finish_initial_deal", INITIAL_DEAL_DELAY_SECONDS)
end

local function hit()
  if phase ~= "player_turn" then return end
  local card = draw()
  card.faceUp = true
  table.insert(playerHand, card)
  phase = "player_settle"
  schedule("finish_player_hit", PLAYER_HIT_DELAY_SECONDS)
end

local function stand()
  if phase ~= "player_turn" then return end
  clearPending()
  startDealerReveal()
end

local function stakeAmount()
  if bet > 0 then
    return bet
  end
  if phase == "resolved" and overhaul_jobs_cardGames_cardGames and overhaul_jobs_cardGames_cardGames.getSessionBet then
    local s = overhaul_jobs_cardGames_cardGames.getSessionBet()
    if type(s) == "number" and s > 0 then
      return s
    end
  end
  return bet
end

local function serializeHand(hand)
  local out = {}
  for i, card in ipairs(hand) do
    table.insert(out, {
      rank = card.rank,
      suit = card.suit,
      faceUp = card.faceUp,
      index = i,
    })
  end
  return out
end

local function getState()
  local playerTotal = handValue(playerHand, false)
  local playerTotalLabel = nil
  if #playerHand > 0 and phase ~= "dealing" and phase ~= "player_settle" then
    if playerTotal > 21 then
      playerTotalLabel = "Bust"
    else
      playerTotalLabel = tostring(playerTotal)
    end
  end
  local dealerTotalLabel = nil
  if phase == "resolved" and #dealerHand > 0 then
    local dealerTotal = handValue(dealerHand, false)
    dealerTotalLabel = dealerTotal > 21 and "Bust" or tostring(dealerTotal)
  elseif #dealerHand > 0 then
    dealerTotalLabel = tostring(handValue(dealerHand, true))
  end
  local stake = stakeAmount()
  local payout = 0
  if result == "blackjack" then
    payout = math.floor(stake * 2.5)
  elseif result == "win" or result == "dealer_bust" then
    payout = stake * 2
  elseif result == "push" then
    payout = stake
  end
  return {
    gameId = "blackjack",
    phase = phase,
    playerCards = serializeHand(playerHand),
    dealerCards = serializeHand(dealerHand),
    playerHandValue = playerTotalLabel,
    dealerHandValue = dealerTotalLabel,
    result = result,
    bet = stake,
    payout = payout,
  }
end

local function resolveOnLeave()
  if phase == "idle" or phase == "resolved" then return end
  clearPending()
  if phase == "player_settle" then
    finishPlayerHit()
    clearPending()
    if phase == "resolved" then return end
  end
  for _, dealerCard in ipairs(dealerHand) do
    dealerCard.faceUp = true
  end
  while shouldDealerHit(dealerHand) do
    local card = draw()
    card.faceUp = true
    table.insert(dealerHand, card)
  end
  phase = "resolved"
  result = resolveResult()
end

local function onAction(name, payload)
  if name == "hit" then hit()
  elseif name == "stand" then stand()
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  gameTime = gameTime + math.max(0, dtSim or 0)
  if not pendingAction or not pendingDeadline then return end
  if gameTime < pendingDeadline then return end
  local action = pendingAction
  clearPending()
  if action == "finish_initial_deal" then
    finishInitialDeal()
  elseif action == "finish_player_hit" then
    finishPlayerHit()
  elseif action == "dealer_continue" then
    continueDealerTurn()
  end
  if overhaul_jobs_cardGames_cardGames and overhaul_jobs_cardGames_cardGames.pushState then
    overhaul_jobs_cardGames_cardGames.pushState()
  end
end

local function onExtensionLoaded()
  if overhaul_jobs_cardGames_cardGames and overhaul_jobs_cardGames_cardGames.register then
    overhaul_jobs_cardGames_cardGames.register("blackjack", M)
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
