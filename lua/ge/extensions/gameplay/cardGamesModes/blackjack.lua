local M = {}

local playerHand = {}
local dealerHand = {}
local phase = "idle"
local bet = 0
local result = nil
local pendingAction = nil
local pendingDeadline = nil

local INITIAL_DEAL_DELAY = 2.05
local PLAYER_HIT_DELAY = 0.52
local DEALER_REVEAL_DELAY = 0.82
local DEALER_HIT_DELAY = 0.52

local function cardValue(card)
  local r = card.rank
  if r == "A" then return 11 end
  if r == "J" or r == "Q" or r == "K" then return 10 end
  return tonumber(r)
end

local function handValue(hand, faceUpOnly)
  local total = 0
  local aces = 0
  for _, c in ipairs(hand) do
    if not faceUpOnly or c.faceUp then
      local v = cardValue(c)
      total = total + v
      if c.rank == "A" then aces = aces + 1 end
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
  for _, c in ipairs(hand) do
    local v = cardValue(c)
    total = total + v
    if c.rank == "A" then aces = aces + 1 end
  end
  while total > 21 and aces > 1 do
    total = total - 10
    aces = aces - 1
  end
  return total == 17 and aces >= 1
end

local function shouldDealerHit(hand)
  local val = handValue(hand, false)
  if val < 17 then return true end
  return false
end

local function draw()
  return gameplay_cardGames.draw()
end

local function reset()
  playerHand = {}
  dealerHand = {}
  phase = "idle"
  bet = 0
  result = nil
  pendingAction = nil
  pendingDeadline = nil
end

local function resolveResult()
  local pv = handValue(playerHand, false)
  local dv = handValue(dealerHand, false)
  if pv > 21 then return "bust" end
  if dv > 21 then return "dealer_bust" end
  if pv > dv then return "win" end
  if pv < dv then return "lose" end
  return "push"
end

local function schedule(action, delay)
  pendingAction = action
  pendingDeadline = os.clock() + delay
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
  schedule("dealer_continue", DEALER_REVEAL_DELAY)
end

local function continueDealerTurn()
  if shouldDealerHit(dealerHand) then
    local c = draw()
    c.faceUp = true
    table.insert(dealerHand, c)
    phase = "dealer_hit"
    schedule("dealer_continue", DEALER_HIT_DELAY)
    return
  end

  phase = "resolved"
  result = resolveResult()
end

local function finishInitialDeal()
  if handValue(playerHand, false) == 21 then
    startDealerReveal()
    return
  end

  phase = "player_turn"
end

local function finishPlayerHit()
  local pv = handValue(playerHand, false)
  if pv > 21 then
    for _, dc in ipairs(dealerHand) do
      dc.faceUp = true
    end
    phase = "resolved"
    result = "bust"
    return
  end

  if pv == 21 then
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
  schedule("finish_initial_deal", INITIAL_DEAL_DELAY)
end

local function hit()
  if phase ~= "player_turn" then return end
  local c = draw()
  c.faceUp = true
  table.insert(playerHand, c)
  phase = "player_settle"
  schedule("finish_player_hit", PLAYER_HIT_DELAY)
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
  if phase == "resolved" and gameplay_cardGames and gameplay_cardGames.getSessionBet then
    local s = gameplay_cardGames.getSessionBet()
    if type(s) == "number" and s > 0 then
      return s
    end
  end
  return bet
end

local function serializeHand(hand)
  local out = {}
  for i, c in ipairs(hand) do
    table.insert(out, {
      rank = c.rank,
      suit = c.suit,
      faceUp = c.faceUp,
      index = i,
    })
  end
  return out
end

local function getState()
  local pv = handValue(playerHand, false)
  local pvLabel = nil
  if #playerHand > 0 and phase ~= "dealing" and phase ~= "player_settle" then
    if pv > 21 then
      pvLabel = "Bust"
    else
      pvLabel = tostring(pv)
    end
  end

  local dvLabel = nil
  if phase == "resolved" and #dealerHand > 0 then
    local dv = handValue(dealerHand, false)
    dvLabel = dv > 21 and "Bust" or tostring(dv)
  elseif #dealerHand > 0 then
    dvLabel = tostring(handValue(dealerHand, true))
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
    playerHandValue = pvLabel,
    dealerHandValue = dvLabel,
    result = result,
    bet = stake,
    payout = payout,
  }
end

local function onAction(name, payload)
  if name == "hit" then hit()
  elseif name == "stand" then stand()
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not pendingAction or not pendingDeadline then return end
  if os.clock() < pendingDeadline then return end

  local action = pendingAction
  clearPending()

  if action == "finish_initial_deal" then
    finishInitialDeal()
  elseif action == "finish_player_hit" then
    finishPlayerHit()
  elseif action == "dealer_continue" then
    continueDealerTurn()
    if result == "dealer_bust" or result == "win" or result == "lose" or result == "push" then
      if handValue(playerHand, false) == 21 and #playerHand == 2 and result ~= "push" then
        result = "blackjack"
      end
    end
  end

  if gameplay_cardGames and gameplay_cardGames.pushState then
    gameplay_cardGames.pushState()
  end
end

local function onExtensionLoaded()
  if gameplay_cardGames and gameplay_cardGames.register then
    gameplay_cardGames.register("blackjack", M)
  end
end

M.reset = reset
M.deal = deal
M.getState = getState
M.onAction = onAction
M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded

return M
