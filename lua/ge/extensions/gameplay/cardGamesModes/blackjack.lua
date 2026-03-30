local M = {}

local playerHand = {}
local dealerHand = {}
local phase = "idle"
local bet = 0
local result = nil

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

local function dealerPlay()
  for _, c in ipairs(dealerHand) do c.faceUp = true end
  while shouldDealerHit(dealerHand) do
    local c = draw()
    c.faceUp = true
    table.insert(dealerHand, c)
  end
  phase = "resolved"
  result = resolveResult()
end

local function deal(betAmount)
  bet = betAmount
  playerHand = {}
  dealerHand = {}
  result = nil

  local p1 = draw(); p1.faceUp = true
  table.insert(playerHand, p1)

  local d1 = draw(); d1.faceUp = true
  table.insert(dealerHand, d1)

  local p2 = draw(); p2.faceUp = true
  table.insert(playerHand, p2)

  local d2 = draw(); d2.faceUp = false
  table.insert(dealerHand, d2)

  phase = "player_turn"

  if handValue(playerHand, false) == 21 then
    dealerPlay()
    if result == "push" then
      result = "push"
    else
      result = "blackjack"
    end
  end
end

local function hit()
  if phase ~= "player_turn" then return end
  local c = draw()
  c.faceUp = true
  table.insert(playerHand, c)
  if handValue(playerHand, false) > 21 then
    phase = "resolved"
    result = "bust"
    for _, dc in ipairs(dealerHand) do dc.faceUp = true end
  end
end

local function stand()
  if phase ~= "player_turn" then return end
  dealerPlay()
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
  if #playerHand > 0 then
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

  return {
    gameId = "blackjack",
    phase = phase,
    playerCards = serializeHand(playerHand),
    dealerCards = serializeHand(dealerHand),
    playerHandValue = pvLabel,
    dealerHandValue = dvLabel,
    result = result,
    bet = bet,
  }
end

local function onAction(name, payload)
  if name == "hit" then hit()
  elseif name == "stand" then stand()
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
M.onExtensionLoaded = onExtensionLoaded

return M
